# syntax=docker/dockerfile:1
# -----------------------------------------------------------------------------
# Stage 1 — pre-build SDL3 (static, per target). System backends are compiled
# with *_SHARED=ON so SDL3 dlopens X11/Wayland/ALSA/Pipewire at runtime on the
# end user's machine — the bundler service host itself never needs them.
# -----------------------------------------------------------------------------
FROM rust:1-slim-trixie AS sdl3-builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential cmake pkg-config \
    ca-certificates curl \
    mingw-w64 \
    libx11-dev libxext-dev libxcursor-dev libxi-dev libxrandr-dev \
    libxss-dev libxkbcommon-dev libxfixes-dev \
    libwayland-dev wayland-protocols libdecor-0-dev \
    libasound2-dev libpulse-dev libpipewire-0.3-dev \
    libdbus-1-dev libudev-dev \
    libdrm-dev libgbm-dev libegl-dev libgl-dev \
    libibus-1.0-dev \
 && rm -rf /var/lib/apt/lists/*

ARG SDL_VERSION=3.4.2

RUN curl -fsSL "https://github.com/libsdl-org/SDL/releases/download/release-${SDL_VERSION}/SDL3-${SDL_VERSION}.tar.gz" \
        | tar -xz -C /tmp

# Max-compatibility CPU baseline (x86_64 ABI minimum: SSE/SSE2).
ARG SDL_CPU_BASELINE="-DSDL_SSE3=OFF -DSDL_SSE4_1=OFF -DSDL_SSE4_2=OFF -DSDL_AVX=OFF -DSDL_AVX2=OFF -DSDL_AVX512F=OFF"

# Linux x86_64: dlopen the system backends. XTEST is off — we don't need
# event injection on the bundler service host.
RUN cmake -S "/tmp/SDL3-${SDL_VERSION}" -B /tmp/build-linux \
        -DCMAKE_BUILD_TYPE=Release \
        -DSDL_SHARED=OFF -DSDL_STATIC=ON \
        -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF \
        -DSDL_INSTALL_DOCS=OFF -DSDL_INSTALL_TESTS=OFF \
        -DSDL_X11_XTEST=OFF \
        ${SDL_CPU_BASELINE} \
        -DCMAKE_INSTALL_PREFIX=/sdl3/linux \
        -DSDL_X11_SHARED=ON -DSDL_WAYLAND_SHARED=ON \
        -DSDL_ALSA_SHARED=ON -DSDL_PULSEAUDIO_SHARED=ON \
        -DSDL_PIPEWIRE_SHARED=ON -DSDL_KMSDRM_SHARED=ON \
 && cmake --build /tmp/build-linux --parallel \
 && cmake --install /tmp/build-linux

# Windows x86_64 via mingw cross.
RUN cmake -S "/tmp/SDL3-${SDL_VERSION}" -B /tmp/build-mingw \
        -DCMAKE_BUILD_TYPE=Release \
        -DSDL_SHARED=OFF -DSDL_STATIC=ON \
        -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF \
        -DSDL_INSTALL_DOCS=OFF -DSDL_INSTALL_TESTS=OFF \
        ${SDL_CPU_BASELINE} \
        -DCMAKE_INSTALL_PREFIX=/sdl3/mingw \
        -DCMAKE_SYSTEM_NAME=Windows \
        -DCMAKE_C_COMPILER=x86_64-w64-mingw32-gcc \
        -DCMAKE_CXX_COMPILER=x86_64-w64-mingw32-g++ \
        -DCMAKE_RC_COMPILER=x86_64-w64-mingw32-windres \
        -DCMAKE_FIND_ROOT_PATH=/usr/x86_64-w64-mingw32 \
        -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
        -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
        -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
 && cmake --build /tmp/build-mingw --parallel \
 && cmake --install /tmp/build-mingw

# pkg-config in the final stage needs `prefix=` to point at the installed
# location, not the build-stage path.
RUN sed -i 's|^prefix=.*|prefix=/src/vendor/sdl3/linux|' \
        /sdl3/linux/lib/pkgconfig/sdl3.pc \
 && sed -i 's|^prefix=.*|prefix=/src/vendor/sdl3/mingw|' \
        /sdl3/mingw/lib/pkgconfig/sdl3.pc

# -----------------------------------------------------------------------------
# Stage 2 — bundler service runtime. Minimal deps (no X11/Wayland/ALSA -dev);
# SDL3 is consumed via the prebuilt static .a + sdl3.pc copied from above.
# -----------------------------------------------------------------------------
FROM rust:1-slim-trixie

COPY bundler/install.sh /tmp/install.sh
RUN /tmp/install.sh \
 && rm -rf /var/lib/apt/lists/* /tmp/install.sh

RUN rustup target add x86_64-pc-windows-gnu

ENV CC_x86_64_pc_windows_gnu=x86_64-w64-mingw32-gcc \
    CXX_x86_64_pc_windows_gnu=x86_64-w64-mingw32-g++ \
    AR_x86_64_pc_windows_gnu=x86_64-w64-mingw32-ar \
    CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER=x86_64-w64-mingw32-gcc

ENV CARGO_HOME=/cargo-cache \
    CARGO_TARGET_DIR=/target-cache
RUN mkdir -p /cargo-cache /target-cache /jobs

WORKDIR /src
COPY . /src
RUN rm -rf /src/.git /src/bundler /src/.github

# Embed prebuilt SDL3 — build.sh's PKG_CONFIG_PATH_<triple> points here.
COPY --from=sdl3-builder /sdl3/linux /src/vendor/sdl3/linux
COPY --from=sdl3-builder /sdl3/mingw /src/vendor/sdl3/mingw

COPY bundler/server.py /usr/local/bin/server.py
COPY bundler/build.sh /usr/local/bin/build.sh
RUN chmod +x /usr/local/bin/build.sh

ENV PYTHONUNBUFFERED=1 \
    BUNDLER_JOBS_DIR=/jobs \
    BUNDLER_SOURCE_DIR=/src \
    BUNDLER_BUILD_SCRIPT=/usr/local/bin/build.sh

EXPOSE 8080
CMD ["python3", "-m", "uvicorn", "--host", "0.0.0.0", "--port", "8080", "--app-dir", "/usr/local/bin", "--proxy-headers", "server:app"]
