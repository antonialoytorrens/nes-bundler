use std::sync::Arc;
use std::sync::atomic::{AtomicU8, Ordering};

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{Device, Host, Stream, StreamConfig};
use ringbuf::traits::Consumer;

use crate::audio::pacer::{AudioConsumer, AudioProducer, make_paced_bridge_ringbuf_bulk_async};
use crate::audio::{AudioStream, AudioSystem, AvailableAudioDevice};
use crate::emulation::DEFAULT_SAMPLE_RATE;
use crate::settings::SettingsStore;

#[derive(Debug, Clone)]
pub struct CpalAvailableAudioDevice {
    name: String,
    is_default: bool,
}

impl CpalAvailableAudioDevice {
    pub fn name(&self) -> String {
        self.name.clone()
    }
}

#[derive(Clone)]
pub struct CpalAudioSystem {
    host: Arc<Host>,
}

impl CpalAudioSystem {
    pub fn new() -> Self {
        Self {
            host: Arc::new(cpal::default_host()),
        }
    }

    pub fn get_available_devices(&self) -> Vec<CpalAvailableAudioDevice> {
        let mut devices = Vec::new();

        if let Some(default) = self.host.default_output_device() {
            devices.push(CpalAvailableAudioDevice {
                name: default.name().unwrap_or_else(|_| "Default".into()),
                is_default: true,
            });
        }

        if let Ok(output_devices) = self.host.output_devices() {
            let default_name = devices.first().map(|d| d.name.clone());
            for dev in output_devices {
                let name = dev.name().unwrap_or_else(|_| "Unknown".into());
                if Some(&name) != default_name.as_ref() {
                    devices.push(CpalAvailableAudioDevice {
                        name,
                        is_default: false,
                    });
                }
            }
        }

        if devices.is_empty() {
            devices.push(CpalAvailableAudioDevice {
                name: "Default output".into(),
                is_default: true,
            });
        }

        devices
    }

    pub fn get_default_device(&self) -> CpalAvailableAudioDevice {
        let name = self
            .host
            .default_output_device()
            .and_then(|d| d.name().ok())
            .unwrap_or_else(|| "Default output".into());
        CpalAvailableAudioDevice {
            name,
            is_default: true,
        }
    }

    pub fn start_stream(&self, settings_store: &SettingsStore) -> AudioStream {
        let mut settings = settings_store.write();
        let device = settings.audio.resolve_output_device(self);
        settings.audio.sync_output_device_selection(&device);
        let volume = settings.audio.volume;
        let latency_micros = settings.audio.latency_micros;
        AudioStream::new(self.clone(), device, volume, latency_micros)
    }

    fn find_device(&self, name: &str) -> Option<Device> {
        self.host
            .output_devices()
            .ok()?
            .find(|d| d.name().ok().as_deref() == Some(name))
    }

    fn output_device(&self, device_info: &CpalAvailableAudioDevice) -> Device {
        if device_info.is_default {
            self.host
                .default_output_device()
                .expect("a default output device")
        } else {
            self.find_device(&device_info.name)
                .or_else(|| self.host.default_output_device())
                .expect("an output device")
        }
    }
}

pub struct CpalAudioStream {
    #[allow(dead_code)]
    audio_system: AudioSystem,
    _stream: Option<Stream>,
    tx: Option<AudioProducer>,
    volume: Arc<AtomicU8>,
    ctl: super::pacer::BridgeCtl,
}

impl CpalAudioStream {
    pub fn take_producer(&mut self) -> AudioProducer {
        self.tx.take().expect("AudioProducer already taken")
    }
}

impl CpalAudioStream {
    fn new(
        audio_system: AudioSystem,
        device_info: AvailableAudioDevice,
        volume: u8,
        latency_micros: u32,
    ) -> Self {
        let (tx, rx, ctl) = make_paced_bridge_ringbuf_bulk_async(
            latency_micros as f64 / 1_000.0,
            DEFAULT_SAMPLE_RATE as f64,
        );

        let volume = Arc::new(AtomicU8::new(volume));
        let stream = Self::create_stream(&audio_system, &device_info, rx, volume.clone());
        Self {
            audio_system,
            _stream: Some(stream),
            tx: Some(tx),
            volume,
            ctl,
        }
    }

    fn create_stream(
        audio_system: &AudioSystem,
        device_info: &AvailableAudioDevice,
        mut rx: AudioConsumer,
        volume: Arc<AtomicU8>,
    ) -> Stream {
        let device = audio_system.output_device(device_info);
        let config = StreamConfig {
            channels: 1,
            sample_rate: cpal::SampleRate(DEFAULT_SAMPLE_RATE as u32),
            buffer_size: cpal::BufferSize::Default,
        };

        let stream = device
            .build_output_stream(
                &config,
                move |data: &mut [f32], _: &cpal::OutputCallbackInfo| {
                    let got = rx.pop_slice(data);
                    let gain = volume.load(Ordering::Relaxed) as f32 / 100.0;
                    for sample in &mut data[..got] {
                        *sample *= gain;
                    }
                    data[got..].fill(0.0);
                },
                |err| log::error!("cpal stream error: {err}"),
                None,
            )
            .expect("output stream to build");

        stream.play().expect("stream to play");
        stream
    }

    pub(crate) fn swap_output_device(&mut self, device: AvailableAudioDevice) {
        log::info!("cpal: device switching not fully supported; keeping current stream");
        let _ = device;
    }

    pub(crate) fn set_volume(&mut self, volume: u8) {
        self.volume.store(volume, Ordering::Relaxed);
    }

    pub(crate) fn set_latency(&self, latency_micros: u32) {
        self.ctl.set_latency_ms(latency_micros as f64 / 1000.0);
    }
}
