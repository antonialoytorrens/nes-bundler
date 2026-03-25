# NES Bundler

**Transform your NES-game into a single executable targeting your favourite OS!**

Did you make a NES-game but none of your friends own a Nintendo? Don't worry.  
Add your ROM and configure NES Bundler to build for Mac, Windows and Linux.  
What you get is a digitally signed executable with
* Simple UI for settings (Show and hide with ESC).
* Re-mappable Keyboard and Gamepad input (you bundle your default mappings).
* Automatic save/load of sram state
* Netplay! (Optional feature, can be disabled if not wanted).

<p align="center">
  <img src="https://github.com/tedsteen/nes-bundler/blob/master/screenshot.gif?raw=true" alt="Data Man!"/>
</p>

## Try it out

Before you make a proper bundle with your own icons and installer graphics you can try out NES Bundler by downloading [your binary of choice](https://github.com/tedsteen/nes-bundler/releases/).  
Running that will start a demo bundle, but if you place your own [config.yaml and/or rom.nes](config/) in the same directory as the executable it will use that.

## Proper bundling

To create a bundle you need to [configure it](config/README.md) with your ROM and a bundle configuration, zip it then send it of for bundling at https://nes-bundler.com/

If everything goes well you should receive emails with the bundles.

## Building

### Desktop (Windows, macOS, Linux)

```bash
cargo build --release
# or for dev
cargo run --profile dev
# with netplay
cargo build --release --features netplay
```

#### Desktop dependencies

* cmake (`brew install cmake`)
* Linux: `sudo apt-get install libxcursor-dev libxi-dev libxrandr-dev libxss-dev libxtst-dev`
* cargo-release (`cargo install cargo-release`, only needed when releasing a new version of nes-bundler)

### Web (WASM)

Requires [Trunk](https://trunkrs.dev/):

```bash
cargo install trunk
rustup target add wasm32-unknown-unknown

# Production build (output in dist/web/)
trunk build --release

# Development server with hot-reload
trunk serve
```

### Android

Requires [xbuild](https://github.com/nickelc/xbuild), the Android NDK and JDK 17:

```bash
cargo install xbuild
rustup target add aarch64-linux-android

# Build APK (arm64)
x build --release --platform android --arch arm64

# Build and run on connected device
x run --release --platform android --arch arm64
```

### Using cargo-make

All build targets are also available via [cargo-make](https://github.com/nickelc/cargo-make):

```bash
cargo install cargo-make

makers build          # Desktop release
makers run            # Desktop dev
makers build-web      # WASM release
makers run-web        # WASM dev server (release)
makers dev-web        # WASM dev server (debug)
makers build-android  # Android APK
makers run-android    # Android build + run
makers lint           # Clippy (all features)
makers lint-web       # Clippy for WASM target
```

### Build script

All build targets are available through `build.sh`:

```bash
./build.sh desktop            # Desktop release
./build.sh desktop --pgo      # Desktop with Profile-Guided Optimization
./build.sh desktop --features netplay  # Desktop with netplay
./build.sh web                # WASM (output in dist/web/)
./build.sh android            # Android APK (arm64)
./build.sh android arm64      # Android APK (explicit arch)
./build.sh all                # All targets
```

Other scripts:
* `release.sh <version>` — publish a new version via `cargo release`