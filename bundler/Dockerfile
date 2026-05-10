FROM rust:1-slim-bookworm

# System packages — single source of truth shared with native deploys.
COPY bundler/install.sh /tmp/install.sh
RUN /tmp/install.sh \
    && rm -rf /var/lib/apt/lists/* /tmp/install.sh

RUN rustup target add x86_64-pc-windows-gnu

# cc/cmake-rs honors these CC_<target> envs for cross-compile.
ENV CC_x86_64_pc_windows_gnu=x86_64-w64-mingw32-gcc \
    CXX_x86_64_pc_windows_gnu=x86_64-w64-mingw32-g++ \
    AR_x86_64_pc_windows_gnu=x86_64-w64-mingw32-ar \
    CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER=x86_64-w64-mingw32-gcc

# Cargo cache + target dir live on persistent volumes (declared in compose).
ENV CARGO_HOME=/cargo-cache \
    CARGO_TARGET_DIR=/target-cache
RUN mkdir -p /cargo-cache /target-cache /jobs

# Bake the source. The `config/` dir is overlayed per-job at runtime.
WORKDIR /src
COPY . /src
RUN rm -rf /src/.git /src/bundler /src/.github

# Service entrypoint.
COPY bundler/server.py /usr/local/bin/server.py
COPY bundler/build.sh /usr/local/bin/build.sh
RUN chmod +x /usr/local/bin/build.sh

ENV PYTHONUNBUFFERED=1 \
    BUNDLER_JOBS_DIR=/jobs \
    BUNDLER_SOURCE_DIR=/src \
    BUNDLER_BUILD_SCRIPT=/usr/local/bin/build.sh

EXPOSE 8080
CMD ["python3", "-m", "uvicorn", "--host", "0.0.0.0", "--port", "8080", "--app-dir", "/usr/local/bin", "--proxy-headers", "server:app"]
