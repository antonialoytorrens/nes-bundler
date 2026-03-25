#![allow(unsafe_code)]
#![deny(clippy::all)]

pub mod app_context;
pub mod app_shell;
pub mod audio;
pub mod bundle;
pub mod emulation;
pub mod game_runtime;
pub mod gui;
pub mod input;
pub mod integer_scaling;
pub mod main_view;
#[cfg(feature = "netplay")]
pub mod netplay;
pub mod settings;
pub mod ui_controller;
pub mod window;

#[derive(Clone, Copy)]
pub struct Size {
    pub width: u32,
    pub height: u32,
}

impl Size {
    pub fn new(width: u32, height: u32) -> Self {
        Self { width, height }
    }
}

// ── Desktop ─────────────────────────────────────────────────────────────────

#[cfg(all(not(target_arch = "wasm32"), not(target_os = "android")))]
pub fn init_logger() {
    #[cfg(windows)]
    {
        match std::fs::OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(true)
            .open("nes-bundler-log.txt")
        {
            Ok(log_file) => {
                env_logger::Builder::from_env(env_logger::Env::default())
                    .target(env_logger::Target::Pipe(Box::new(log_file)))
                    .init();
            }
            Err(e) => {
                env_logger::init();
                log::warn!("Could not open nes-bundler-log.txt for writing, {:?}", e)
            }
        }
    }
    #[cfg(not(windows))]
    {
        env_logger::init();
    }
}

#[cfg(all(not(target_arch = "wasm32"), not(target_os = "android")))]
pub fn run_desktop() -> anyhow::Result<()> {
    use audio::gui::AudioGui;
    use input::Inputs;
    use input::gui::InputsGui;
    use input::sdl3_impl::SDL3Gamepads;
    use sdl3::EventPump;

    use crate::app_context::AppContext;
    use crate::app_shell::AppShell;
    use crate::audio::AudioSystem;
    use crate::emulation::gui::EmulatorGui;
    use crate::game_runtime::GameRuntime;
    use crate::main_view::gui::MainGui;
    use crate::ui_controller::UiController;
    use winit::event_loop::EventLoop;

    let app_context = AppContext::global();
    let event_loop = EventLoop::new()?;
    event_loop.set_control_flow(winit::event_loop::ControlFlow::Poll);

    sdl3::hint::set("SDL_JOYSTICK_THREAD", "1");
    let sdl3_context = sdl3::init().map_err(anyhow::Error::msg)?;
    let sdl_event_pump: EventPump = sdl3_context.event_pump().map_err(anyhow::Error::msg)?;

    let audio_system = AudioSystem::new(sdl3_context.audio().expect("An SDL audio subsystem"));
    let settings = app_context.settings();
    let mut stream = audio_system.start_stream(settings);

    let runtime = GameRuntime::new(&mut stream);
    let shared_state = runtime.shared_state();

    let inputs = Inputs::new(SDL3Gamepads::new(
        sdl3_context.gamepad().map_err(anyhow::Error::msg)?,
    ));

    let main_gui = MainGui::new(
        shared_state.emulator.command_tx.clone(),
        AudioGui::new(audio_system.clone(), stream, settings),
        InputsGui::new(inputs, settings),
        EmulatorGui::new(shared_state),
        app_context.config().supported_nes_regions.clone(),
        settings,
    );
    let ui = UiController::new(main_gui, std::time::Duration::from_secs(1));
    let shell = &mut AppShell::new(app_context, runtime, sdl_event_pump, ui);
    event_loop.run_app(shell)?;

    Ok(())
}

#[cfg(all(not(target_arch = "wasm32"), not(target_os = "android")))]
pub fn check_netplay_cli() {
    #[cfg(feature = "netplay")]
    if std::env::args().any(|arg| arg == "--print-netplay-id") {
        let app = app_context::AppContext::global();
        if let netplay::configuration::NetplayServerConfiguration::TurnOn(turn_on_config) =
            &app.config().netplay.server
        {
            println!("{0}", turn_on_config.resolved_netplay_id());
            std::process::exit(0);
        } else {
            eprintln!(
                "Netplay id not applicable for {0:#?}",
                app.config().netplay.server
            );
            std::process::exit(1);
        }
    }
}

// ── WASM ────────────────────────────────────────────────────────────────────

#[cfg(target_arch = "wasm32")]
pub mod wasm {
    use wasm_bindgen::prelude::*;

    #[wasm_bindgen(start)]
    pub fn wasm_main() {
        console_error_panic_hook::set_once();
        console_log::init_with_level(log::Level::Info).expect("logger to init");
        log::info!("NES Bundler WASM is starting!");

        wasm_bindgen_futures::spawn_local(async {
            if let Err(e) = run_wasm().await {
                log::error!("NES Bundler WASM failed: {:?}", e);
            }
        });
    }

    async fn run_wasm() -> anyhow::Result<()> {
        use crate::app_context::AppContext;
        use crate::app_shell::AppShell;
        use crate::audio::AudioSystem;
        use crate::audio::gui::AudioGui;
        use crate::emulation::gui::EmulatorGui;
        use crate::game_runtime::GameRuntime;
        use crate::input::Inputs;
        use crate::input::PlatformGamepads;
        use crate::input::gui::InputsGui;
        use crate::main_view::gui::MainGui;
        use crate::ui_controller::UiController;
        use winit::event_loop::EventLoop;

        let app_context = AppContext::global();
        let event_loop = EventLoop::new()?;
        event_loop.set_control_flow(winit::event_loop::ControlFlow::Poll);

        let audio_system = AudioSystem::new();
        let settings = app_context.settings();
        let mut stream = audio_system.start_stream(settings);

        let runtime = GameRuntime::new(&mut stream);
        let shared_state = runtime.shared_state();

        let inputs = Inputs::new(PlatformGamepads::new());

        let main_gui = MainGui::new(
            shared_state.emulator.command_tx.clone(),
            AudioGui::new(audio_system.clone(), stream, settings),
            InputsGui::new(inputs, settings),
            EmulatorGui::new(shared_state),
            app_context.config().supported_nes_regions.clone(),
            settings,
        );
        let ui = UiController::new(
            main_gui,
            std::time::Duration::from_secs(1),
        );
        let shell = &mut AppShell::new(app_context, runtime, ui);
        event_loop.run_app(shell)?;

        Ok(())
    }
}

// ── Android ─────────────────────────────────────────────────────────────────

#[cfg(target_os = "android")]
#[unsafe(no_mangle)]
pub fn android_main(_app: winit::platform::android::activity::AndroidApp) {
    android_logger::init_once(
        android_logger::Config::default().with_max_level(log::LevelFilter::Info),
    );
    log::info!("NES Bundler Android is starting!");

    if let Err(e) = run_android() {
        log::error!("NES Bundler Android failed: {:?}", e);
    }
}

#[cfg(target_os = "android")]
fn run_android() -> anyhow::Result<()> {
    use crate::app_context::AppContext;
    use crate::app_shell::AppShell;
    use crate::audio::AudioSystem;
    use crate::audio::gui::AudioGui;
    use crate::emulation::gui::EmulatorGui;
    use crate::game_runtime::GameRuntime;
    use crate::input::Inputs;
    use crate::input::PlatformGamepads;
    use crate::input::gui::InputsGui;
    use crate::main_view::gui::MainGui;
    use crate::ui_controller::UiController;
    use winit::event_loop::EventLoop;

    let app_context = AppContext::global();
    let event_loop = EventLoop::new()?;
    event_loop.set_control_flow(winit::event_loop::ControlFlow::Poll);

    let audio_system = AudioSystem::new();
    let settings = app_context.settings();
    let mut stream = audio_system.start_stream(settings);

    let runtime = GameRuntime::new(&mut stream);
    let shared_state = runtime.shared_state();

    let inputs = Inputs::new(PlatformGamepads::new());

    let main_gui = MainGui::new(
        shared_state.emulator.command_tx.clone(),
        AudioGui::new(audio_system.clone(), stream, settings),
        InputsGui::new(inputs, settings),
        EmulatorGui::new(shared_state),
        app_context.config().supported_nes_regions.clone(),
        settings,
    );
    let ui = UiController::new(main_gui, std::time::Duration::from_secs(1));
    let shell = &mut AppShell::new(app_context, runtime, ui);
    event_loop.run_app(shell)?;

    Ok(())
}
