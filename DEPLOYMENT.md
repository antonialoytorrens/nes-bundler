# Deploying the bundler to a VPS

This service builds Linux + Windows binaries from a Rust source tree on every request, so the host needs to be sized like a build server — not a webapp host.

## VPS sizing

| Resource | Minimum | Comfortable |
|----------|---------|-------------|
| RAM      | 4 GB    | 8 GB        |
| CPU      | 2 vCPU  | 4 vCPU      |
| Disk     | 20 GB   | 40 GB       |

The first build takes 15–30 min (SDL3 compiles from C, plus the full Rust dep tree). After that, the persistent `bundler_cargo` and `bundler_target` volumes mean per-job builds drop to a few minutes — but they grow over time. Plan disk accordingly.

If your VPS has < 4 GB RAM, set `CARGO_BUILD_JOBS=1` in `.env` (add it to the `environment:` block in `docker-compose.yml`) so the linker doesn't OOM.

## Prerequisites on the VPS

Debian/Ubuntu:

```bash
sudo apt update
sudo apt install -y git ca-certificates curl

# Docker engine + compose plugin (official one-liner)
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker "$USER"
# log out and back in for the group change to apply
```

Verify:

```bash
docker --version
docker compose version
```

## First deploy

```bash
git clone https://github.com/tedsteen/nes-bundler.git
cd nes-bundler
cp .env.example .env
$EDITOR .env       # tweak BUNDLER_PORT / BUNDLER_ALLOWED_IPS
docker compose up -d --build
docker compose logs -f bundler
```

Health check:

```bash
curl http://127.0.0.1:8080/health
# {"ok":true}
```

## Alternative: native deployment (no Docker)

If you'd rather not run Docker on the VPS, run the service directly under systemd. The trade-off: you maintain the build-deps stack on the host yourself, and updates are `git pull && systemctl restart` instead of an image rebuild.

The instructions below assume Debian/Ubuntu and a service user named `bundler`.

### 1. Create a service user + directories

```bash
sudo useradd --system --create-home --home-dir /var/lib/bundler --shell /usr/sbin/nologin bundler
sudo mkdir -p /opt/nes-bundler /var/lib/bundler/{jobs,cargo,target}
sudo chown -R bundler:bundler /opt/nes-bundler /var/lib/bundler
```

### 2. Clone the repo

```bash
sudo -u bundler git clone https://github.com/tedsteen/nes-bundler.git /opt/nes-bundler
```

### 3. Install system dependencies

The same script the Dockerfile uses — apt only, no pip:

```bash
sudo /opt/nes-bundler/bundler/install.sh
```

### 4. Install Rust + the Windows target as the service user

The Debian-packaged `rustc` is too old for edition 2024, so use rustup:

```bash
sudo -u bundler -H bash -c '
  curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
  source $HOME/.cargo/env
  rustup target add x86_64-pc-windows-gnu
'
```

### 5. Make `build.sh` executable

```bash
sudo chmod +x /opt/nes-bundler/bundler/build.sh
```

### 6. Environment file

`/etc/nes-bundler.env`:

```ini
BUNDLER_PORT=8080
BUNDLER_ALLOWED_IPS=*
BUNDLER_MAX_CONCURRENT=1

BUNDLER_JOBS_DIR=/var/lib/bundler/jobs
BUNDLER_SOURCE_DIR=/opt/nes-bundler
BUNDLER_BUILD_SCRIPT=/opt/nes-bundler/bundler/build.sh

CARGO_HOME=/var/lib/bundler/cargo
CARGO_TARGET_DIR=/var/lib/bundler/target

# mingw cross-compile env (mirrors the Dockerfile)
CC_x86_64_pc_windows_gnu=x86_64-w64-mingw32-gcc
CXX_x86_64_pc_windows_gnu=x86_64-w64-mingw32-g++
AR_x86_64_pc_windows_gnu=x86_64-w64-mingw32-ar
CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER=x86_64-w64-mingw32-gcc

PATH=/var/lib/bundler/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
```

```bash
sudo chmod 600 /etc/nes-bundler.env
sudo chown bundler:bundler /etc/nes-bundler.env
```

### 7. systemd unit

`/etc/systemd/system/nes-bundler.service`:

```ini
[Unit]
Description=nes-bundler bundler service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=bundler
Group=bundler
WorkingDirectory=/opt/nes-bundler
EnvironmentFile=/etc/nes-bundler.env
ExecStart=/usr/bin/python3 -m uvicorn \
    --host 0.0.0.0 --port ${BUNDLER_PORT} \
    --proxy-headers \
    --app-dir /opt/nes-bundler/bundler \
    server:app
Restart=on-failure
RestartSec=5
# Sandboxing
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/bundler /opt/nes-bundler/config

[Install]
WantedBy=multi-user.target
```

`ReadWritePaths` includes `/opt/nes-bundler/config` because `build.sh` swaps the user-supplied config into the source tree on each job. If you'd rather keep the source tree read-only, change `build.sh` to copy the source into a per-job workspace instead.

### 8. Start it

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now nes-bundler
sudo systemctl status nes-bundler
curl http://127.0.0.1:8080/health
```

### Native equivalents for the Docker sections below

| Task | Docker | Native |
|------|--------|--------|
| Live logs | `docker compose logs -f bundler` | `journalctl -u nes-bundler -f` |
| Shell into the service | `docker compose exec bundler bash` | `sudo -u bundler -H bash` |
| Update | `git pull && docker compose up -d --build` | `cd /opt/nes-bundler && sudo -u bundler git pull && sudo systemctl restart nes-bundler` |
| Prune old jobs | `docker compose exec bundler find /jobs -mtime +7 -delete` | `sudo find /var/lib/bundler/jobs -maxdepth 1 -mindepth 1 -type d -mtime +7 -exec rm -rf {} +` |
| Wipe cargo + target caches | `docker volume rm ...` | `sudo rm -rf /var/lib/bundler/{cargo,target}/* && sudo systemctl restart nes-bundler` |

The reverse-proxy and firewall sections that follow apply unchanged — just bind uvicorn to `127.0.0.1` in the unit's `ExecStart` line if you want it behind nginx instead of public.

## Firewall

Open only the port you actually expose. With `ufw`:

```bash
sudo ufw allow OpenSSH
sudo ufw allow 8080/tcp        # or whatever BUNDLER_PORT you set
sudo ufw enable
```

If you put the service behind a reverse proxy (recommended), keep `8080` bound to localhost only and open `80/443` instead — see below.

## Reverse proxy + TLS (recommended for public access)

Plain HTTP on a public port is fine for testing but has two real problems: the bundle endpoint accepts uploads (you want size limits + TLS) and the IP allowlist is bypassable on plaintext.

Minimal nginx + Let's Encrypt setup (Debian/Ubuntu):

```bash
sudo apt install -y nginx certbot python3-certbot-nginx
```

Bind the bundler to localhost in `docker-compose.yml`:

```yaml
    ports:
      - "127.0.0.1:8080:8080"
```

`/etc/nginx/sites-available/bundler.conf`:

```nginx
server {
    listen 80;
    server_name bundler.example.com;

    # Match the size of your largest config.zip uploads
    client_max_body_size 50M;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # Bundle builds take minutes; bump proxy timeouts.
        proxy_read_timeout 30m;
        proxy_send_timeout 30m;
    }
}
```

Enable + grab a cert:

```bash
sudo ln -s /etc/nginx/sites-available/bundler.conf /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
sudo certbot --nginx -d bundler.example.com
```

Behind a proxy, the bundler sees `127.0.0.1` as the client IP unless you trust `X-Forwarded-For` — uvicorn already runs with `--proxy-headers`, so it picks up the value nginx sets above. If you want IP allowlisting to actually filter on the real client, keep `BUNDLER_ALLOWED_IPS=*` and instead allowlist at the nginx layer with `allow`/`deny` directives.

## Using it

From a client machine:

```bash
cd config && ./prepare.sh && cd ..
curl -X POST -F "config=@config/config.zip" https://bundler.example.com/bundle
# {"job_id":"abc...","status_url":".../jobs/abc...","download_url":".../jobs/abc.../download","log_url":".../jobs/abc.../log"}
```

Poll status, then download:

```bash
JOB=abc...
curl https://bundler.example.com/jobs/$JOB
# {"status":"running",...}  →  {"status":"done",...}

curl -O https://bundler.example.com/jobs/$JOB/download
# nes-bundler-abc....tar.gz
```

If a build fails, the response includes an `error` field and `log_url` shows the full cargo output.

## Updating

```bash
cd nes-bundler
git pull
docker compose up -d --build
```

The cargo + target volumes survive image rebuilds, so updates only re-link the binary, not recompile every dep.

## Disk hygiene

Three volumes grow over time:

| Volume            | What's in it                       | When to prune |
|-------------------|------------------------------------|---------------|
| `bundler_jobs`    | One dir per job (zip + tarball)    | Often         |
| `bundler_target`  | Cargo build outputs (per target)   | Rarely        |
| `bundler_cargo`   | Cargo registry + git deps          | Rarely        |

Prune jobs older than 7 days:

```bash
docker compose exec bundler \
  find /jobs -maxdepth 1 -mindepth 1 -type d -mtime +7 -exec rm -rf {} +
```

Drop the cargo/target caches (forces the next build to recompile everything):

```bash
docker compose down
docker volume rm nes-bundler_bundler_target nes-bundler_bundler_cargo
docker compose up -d --build
```

## Logs and debugging

```bash
docker compose logs -f bundler          # live service log
docker compose exec bundler bash        # shell in the container
docker compose ps                       # container status
```

Per-job build logs live at `/jobs/<job_id>/build.log` inside the container, also exposed via `GET /jobs/<job_id>/log`.

## Things that will probably need iteration on first deploy

- **SDL3 mingw cross-compile**. The Linux build is well-trodden; the Windows cross via `mingw-w64` is the riskier path. If the Windows build fails on the first job, expect to add SDL-specific CMake flags via `CMAKE_TOOLCHAIN_FILE_x86_64_pc_windows_gnu` or extra `RUSTFLAGS` for the Windows target. The build log (`/jobs/<id>/build.log`) will tell you what's missing.
- **Build memory pressure** with `lto = true` or parallel rustc jobs on small VPSes. If you see linker OOM, drop `CARGO_BUILD_JOBS=1`.
- **`request.client.host` behind a proxy.** As noted above, allowlist at the nginx layer if you want real-IP filtering with TLS termination.
