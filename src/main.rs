#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    nes_bundler::init_logger();
    nes_bundler::check_netplay_cli();

    log::info!("NES Bundler is starting!");
    if let Err(e) = nes_bundler::run_desktop() {
        log::error!("nes-bundler failed to run :(\n{:?}", e)
    }
}
