use crate::{
    audio::AudioSettings,
    bundle::Bundle,
    emulation::NesRegion,
    input::{InputConfigurationKind, settings::InputSettings},
};

use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::{
    collections::hash_map::DefaultHasher,
    hash::{Hash, Hasher},
    ops::{Deref, DerefMut},
    sync::{OnceLock, RwLock, RwLockReadGuard, RwLockWriteGuard},
};

pub const MAX_PLAYERS: usize = 2;

pub struct AutoSavingSettings<'a> {
    inner: RwLockWriteGuard<'a, Settings>,
    hash_before: u64,
}

impl<'a> AutoSavingSettings<'a> {
    fn new(inner: &'a RwLock<Settings>) -> Self {
        let inner = inner.write().unwrap();
        AutoSavingSettings {
            hash_before: inner.get_hash(),
            inner,
        }
    }
}

impl Deref for AutoSavingSettings<'_> {
    type Target = Settings;

    fn deref(&self) -> &Settings {
        &self.inner
    }
}

impl DerefMut for AutoSavingSettings<'_> {
    fn deref_mut(&mut self) -> &mut Settings {
        &mut self.inner
    }
}

impl Drop for AutoSavingSettings<'_> {
    fn drop(&mut self) {
        if self.hash_before != self.inner.get_hash() {
            self.inner.save()
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, Hash)]
pub struct Settings {
    pub audio: AudioSettings,
    pub input: InputSettings,
    pub netplay_id: Option<String>,
    pub save_state: Option<String>,
    nes_region: Option<NesRegion>,
}

pub struct SettingsStore {
    inner: RwLock<Settings>,
}

impl SettingsStore {
    pub fn new() -> Self {
        Self {
            inner: RwLock::new(Settings::load()),
        }
    }

    pub fn global() -> &'static Self {
        static MEM: OnceLock<SettingsStore> = OnceLock::new();
        MEM.get_or_init(SettingsStore::new)
    }

    pub fn write(&self) -> AutoSavingSettings<'_> {
        AutoSavingSettings::new(&self.inner)
    }

    pub fn read(&self) -> RwLockReadGuard<'_, Settings> {
        self.inner.read().unwrap()
    }
}

impl Settings {
    pub fn current_mut<'a>() -> AutoSavingSettings<'a> {
        SettingsStore::global().write()
    }

    pub fn current<'a>() -> RwLockReadGuard<'a, Settings> {
        SettingsStore::global().read()
    }

    #[cfg(feature = "netplay")]
    pub fn ensure_netplay_id(&mut self) -> String {
        self.netplay_id
            .get_or_insert_with(|| uuid::Uuid::new_v4().to_string())
            .to_string()
    }

    fn load() -> Settings {
        let bundle = Bundle::current();
        let default_settings = bundle.config.default_settings.clone();

        let mut settings: Result<Settings> = Self::load_from_storage(bundle);

        match &mut settings {
            Ok(settings) => {
                let default_selected = default_settings.input.selected.clone();
                for (player, default_selected_input) in
                    default_selected.iter().enumerate().take(MAX_PLAYERS)
                {
                    if let InputConfigurationKind::Gamepad(_) =
                        &settings.input.selected_configuration(player).kind
                    {
                        settings.input.selected[player].clone_from(default_selected_input);
                    }
                }
            }
            Err(e) => log::warn!("Could not load settings: {:?}", e),
        }
        settings.unwrap_or(default_settings)
    }

    #[cfg(not(target_arch = "wasm32"))]
    fn load_from_storage(bundle: &Bundle) -> Result<Settings> {
        let settings_file_path = bundle.settings_path.join("settings.yaml");
        let f = std::fs::File::open(&settings_file_path).map_err(anyhow::Error::msg)?;
        serde_yaml::from_reader(std::io::BufReader::new(f)).map_err(anyhow::Error::msg)
    }

    #[cfg(target_arch = "wasm32")]
    fn load_from_storage(_bundle: &Bundle) -> Result<Settings> {
        let storage = web_sys::window()
            .and_then(|w| w.local_storage().ok().flatten())
            .ok_or_else(|| anyhow::anyhow!("localStorage not available"))?;
        let data = storage
            .get_item("nes-bundler-settings")
            .map_err(|_| anyhow::anyhow!("failed to read localStorage"))?
            .ok_or_else(|| anyhow::anyhow!("no saved settings"))?;
        serde_yaml::from_str(&data).map_err(anyhow::Error::msg)
    }

    fn save(&self) {
        #[cfg(not(target_arch = "wasm32"))]
        {
            let settings_file_path = &Bundle::current().settings_path.join("settings.yaml");
            if let Err(e) = std::fs::File::create(settings_file_path)
                .map_err(anyhow::Error::msg)
                .and_then(|file| {
                    serde_yaml::to_writer(std::io::BufWriter::new(file), self)
                        .map_err(anyhow::Error::msg)
                })
            {
                log::error!("Failed to save settings: {:?}", e);
            } else {
                log::debug!("Settings saved");
            }
        }

        #[cfg(target_arch = "wasm32")]
        {
            if let Some(storage) = web_sys::window().and_then(|w| w.local_storage().ok().flatten())
            {
                match serde_yaml::to_string(self) {
                    Ok(data) => {
                        let _ = storage.set_item("nes-bundler-settings", &data);
                        log::debug!("Settings saved to localStorage");
                    }
                    Err(e) => log::error!("Failed to serialize settings: {:?}", e),
                }
            }
        }
    }

    fn get_hash(&self) -> u64 {
        let hasher = &mut DefaultHasher::new();
        self.hash(hasher);
        hasher.finish()
    }

    pub fn nes_region_mut(&mut self) -> &mut NesRegion {
        self.nes_region
            .get_or_insert_with(|| Bundle::current().config.default_region().clone())
    }
}
