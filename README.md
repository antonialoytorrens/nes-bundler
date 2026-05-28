# NES Bundler

**Transform your NES-game into a single executable targeting your favourite OS!**

Did you make a NES-game but none of your friends own a Nintendo? Don't worry.
Add your ROM and configure NES Bundler to build for Windows and Linux.
What you get is an executable with

* Simple UI for settings (Show and hide with ESC).
* Re-mappable Keyboard and Gamepad input (you bundle your default mappings).
* Automatic save/load of sram state.

<p align="center">
  <img src="https://github.com/tedsteen/nes-bundler/blob/master/screenshot.gif?raw=true" alt="Data Man!"/>
</p>

## Try it out

Download a binary from [Releases](https://github.com/tedsteen/nes-bundler/releases/). It starts a demo bundle, but if you drop your own [config.yaml and/or rom.nes](config/) next to the executable it will use those.

## Bundling your own game

[Configure your bundle](config/README.md), zip it with `config/prepare.sh`, and POST the zip — together with the bundler's shared `token` — to your bundler service:

```bash
curl -X POST \
  -F "token=$BUNDLER_TOKEN" \
  -F "config=@config.zip" \
  https://your-bundler.example/bundle
# {"job_id":"...","status_url":"...","download_url":"...","log_url":"..."}
```

`BUNDLER_TOKEN` is the shared secret configured on the server (see `.env.example`). Requests without it — or with the wrong value — are rejected with `401 invalid or missing token`. Generate one with `openssl rand -hex 32` and share it out-of-band with whoever is allowed to submit builds.

Poll `status_url` until status is `done`, then GET `download_url` for a tarball containing the Linux and Windows builds. See [bundler/](bundler/) for how to run that service yourself.

## Building locally

```bash
cargo build --release
# or for dev
cargo run --profile dev
```

### Dependencies

* `cmake`
* SDL3 build deps (X11/Wayland/audio dev headers on Linux — see [bundler/Dockerfile](bundler/Dockerfile) for the full apt list)
* `cargo-release` (only needed when releasing a new version of nes-bundler)

## Running the bundler service

The `bundler/` service builds Linux x86_64 + Windows x86_64 (cross-compiled with `mingw-w64`) on a single Linux host. Bring it up with Docker Compose:

```bash
cp .env.example .env
# Set BUNDLER_TOKEN to a long random string — the service won't start without it:
#   sed -i "s|^BUNDLER_TOKEN=.*|BUNDLER_TOKEN=$(openssl rand -hex 32)|" .env
docker compose up -d --build
docker compose logs -f bundler
```

The first build is slow because SDL3 + the full dep tree compile from scratch; subsequent jobs reuse the persistent cargo + target volumes.
