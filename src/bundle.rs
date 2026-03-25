use std::{
    path::{Path, PathBuf},
    sync::OnceLock,
};

use anyhow::Result;
use serde::Deserialize;

use crate::{emulation::NesRegion, input::gui::InputButtonsVoca, settings::Settings};

#[derive(Deserialize, Default, Debug)]
pub struct Vocabulary {
    #[serde(default = "Default::default")]
    pub input_buttons: InputButtonsVoca,

    #[cfg(feature = "netplay")]
    #[serde(default = "Default::default")]
    pub netplay: crate::netplay::gui::NetplayVoca,
}

#[derive(Deserialize, Debug)]
pub struct BuildConfiguration {
    pub name: String,
    pub manufacturer: String,
    pub default_settings: Settings,
    pub supported_nes_regions: Vec<NesRegion>,
    #[serde(default = "Default::default")]
    pub enable_vsync: bool,
    #[serde(default = "Default::default")]
    pub start_in_fullscreen: bool,
    #[serde(default = "Default::default")]
    pub vocabulary: Vocabulary,

    #[cfg(feature = "netplay")]
    pub netplay: crate::netplay::configuration::NetplayBuildConfiguration,
}

impl BuildConfiguration {
    pub fn default_region(&self) -> &NesRegion {
        self.supported_nes_regions
            .first()
            .expect("at least one supported nes region")
    }

    pub fn config_dir(&self) -> Option<PathBuf> {
        #[cfg(all(not(target_arch = "wasm32"), not(target_os = "android")))]
        {
            let path = directories::ProjectDirs::from("", &self.manufacturer, &self.name)
                .map(|pd| pd.config_dir().to_path_buf());
            if let Some(path) = path.clone()
                && let Err(e) = std::fs::create_dir_all(path)
            {
                log::error!("Could not create path: {:?}", e);
            }
            path
        }

        #[cfg(target_os = "android")]
        {
            let path = PathBuf::from("/data/data/com.nesbundler/files");
            if let Err(e) = std::fs::create_dir_all(&path) {
                log::error!("Could not create Android config path: {:?}", e);
            }
            Some(path)
        }

        #[cfg(target_arch = "wasm32")]
        {
            Some(PathBuf::from(""))
        }
    }
}

pub struct Bundle {
    pub settings_path: PathBuf,
    pub config: BuildConfiguration,
    pub rom: Vec<u8>,
    #[cfg(feature = "netplay")]
    pub netplay_rom: Vec<u8>,
}
impl Bundle {
    pub fn current() -> &'static Bundle {
        static MEM: OnceLock<Bundle> = OnceLock::new();
        MEM.get_or_init(|| Bundle::load().expect("bundle to load"))
    }

    fn load() -> Result<Bundle> {
        let (external_config, external_rom) = Self::load_external_files();

        let config: BuildConfiguration =
            external_config.unwrap_or(serde_yaml::from_str(include_str!("../config/config.yaml"))?);

        let rom = external_rom.unwrap_or(include_bytes!("../config/rom.nes").to_vec());

        let settings_path = config.config_dir().unwrap_or(Path::new("").to_path_buf());

        log::debug!("Settings path: {:?}", settings_path);

        Ok(Bundle {
            settings_path,
            config,
            rom,

            #[cfg(feature = "netplay")]
            netplay_rom: Self::load_netplay_rom(),
        })
    }

    #[cfg(not(target_arch = "wasm32"))]
    fn load_external_files() -> (Option<BuildConfiguration>, Option<Vec<u8>>) {
        let external_config = std::fs::read_to_string(Path::new("config.yaml"))
            .inspect_err(|e| log::info!("Not using external config.yaml: {:?}", e))
            .map_err(anyhow::Error::msg)
            .and_then(|config| serde_yaml::from_str(&config).map_err(anyhow::Error::msg))
            .ok();

        let external_rom = std::fs::read(Path::new("rom.nes"))
            .inspect_err(|e| log::info!("Not using external rom.nes: {:?}", e))
            .ok();

        (external_config, external_rom)
    }

    #[cfg(target_arch = "wasm32")]
    fn load_external_files() -> (Option<BuildConfiguration>, Option<Vec<u8>>) {
        (None, None)
    }

    #[cfg(feature = "netplay")]
    fn load_netplay_rom() -> Vec<u8> {
        #[cfg(not(target_arch = "wasm32"))]
        {
            std::fs::read(Path::new("netplay-rom.nes"))
                .inspect_err(|e| log::info!("Not using external netplay-rom.nes: {:?}", e))
                .unwrap_or(include_bytes!("../config/netplay-rom.nes").to_vec())
        }
        #[cfg(target_arch = "wasm32")]
        {
            include_bytes!("../config/netplay-rom.nes").to_vec()
        }
    }
}
