# obf-build-base - compiler base image for obfuscated Rust builds.
#
# Everything project-agnostic lives here: the system toolchain, the pinned
# cross-compilation support (zig via cargo-zigbuild, MinGW, musl-tools,
# rcodesign for Mach-O ad-hoc signing) and the obfuscating Rust/LLVM
# toolchain releases. Downstream projects FROM this image by digest and add
# only their own tail (project code, vendored dependencies, project-specific
# patch steps, entrypoint).
#
# Reproducibility notes:
# - Every toolchain input is pinned: the rustup toolchain version, the
#   cargo-zigbuild version (which pins the bundled zig), the rcodesign
#   release and the obfuscation toolchain release tag. A digest-pinned
#   FROM in downstream Dockerfiles then gives fully pinned builds end to
#   end.
# - apt package versions are NOT pinned (no snapshot mirror); they drift
#   between base rebuilds. The C/C++ dependencies of downstream projects
#   are compiled by zig (cargo-zigbuild) rather than the system gcc, so
#   this drift has not been observed to affect produced binaries, but it
#   is why base rebuilds get a new digest and downstream projects
#   re-verify after rebasing onto it.

FROM ubuntu:26.04

# Prevent interactive prompts during apt installs
ENV DEBIAN_FRONTEND=noninteractive

# Install core build utilities, MinGW for Windows, and Python for zig/zigbuild
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    git \
    musl-tools \
    gcc-mingw-w64-x86-64 \
    python3 \
    python3-dev \
    python3-pip \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# Install Zig and cargo-zigbuild via pip (precompiled zig binaries keep the
# image build fast). PINNED: the cargo-zigbuild version pins the bundled zig
# version, which pins the linker and the C runtime it provides.
RUN pip3 install --no-cache-dir --timeout 120 --break-system-packages cargo-zigbuild==0.24.0

# Install Rust toolchain. PINNED: a channel-less version instead of
# "stable", which would float with every new release.
ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:$PATH

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain 1.99.1 --profile minimal \
    && chmod -R a+w /usr/local/cargo /usr/local/rustup

# Install targets for x86, x86_64, ARM64, and ARM (32-bit)
RUN rustup target add \
    # Linux x86, x86_64 & ARM64
    i686-unknown-linux-musl \
    i686-unknown-linux-gnu \
    x86_64-unknown-linux-musl \
    x86_64-unknown-linux-gnu \
    aarch64-unknown-linux-musl \
    aarch64-unknown-linux-gnu \
    # Linux 32-bit ARM (Raspberry Pi, embedded)
    armv7-unknown-linux-musleabihf \
    armv7-unknown-linux-gnueabihf \
    # Windows x86, x86_64 & ARM64
    i686-pc-windows-gnu \
    x86_64-pc-windows-gnu \
    aarch64-pc-windows-gnullvm \
    # macOS Intel & Apple Silicon
    x86_64-apple-darwin \
    aarch64-apple-darwin

# Configure Cargo linkers for MinGW Windows targets (project trees carry
# their own .cargo/config.toml with these tables as well; this copy is the
# CARGO_HOME-level fallback so bare tooling invoked outside a project tree
# still links windows-gnu targets).
RUN mkdir -p /usr/local/cargo && cat <<'EOF' > /usr/local/cargo/config.toml
[target.x86_64-pc-windows-gnu]
linker = "x86_64-w64-mingw32-gcc"
ar = "x86_64-w64-mingw32-gcc-ar"
EOF

# Install rcodesign for macOS Mach-O ad-hoc signing
ARG RCODESIGN_VERSION=0.29.0
RUN ARCH=$(uname -m) && \
    curl -fsSL "https://github.com/indygreg/apple-platform-rs/releases/download/apple-codesign%2F${RCODESIGN_VERSION}/apple-codesign-${RCODESIGN_VERSION}-${ARCH}-unknown-linux-musl.tar.gz" \
    | tar -xz -C /usr/local/bin --strip-components=1 "apple-codesign-${RCODESIGN_VERSION}-${ARCH}-unknown-linux-musl/rcodesign" \
    && chmod +x /usr/local/bin/rcodesign

# Obfuscating Rust toolchain (forked LLVM 23.1.3 + pinned Rust 1.99 with the
# obf-* passes; multi-backend, cross-target std prebuilt). Downloaded from a
# plain release URL - no auth. OBF_REPO_BASE can be pointed at a LAN mirror
# (e.g. http://llmproxy/llvm-project/releases/download) instead.
ARG OBF_REPO_BASE=https://github.com/stephenbradshaw/llvm-project/releases/download
ARG OBF_TAG=v23.1.3.10
RUN ARCH=$(uname -m) && \
    case "$ARCH" in \
        x86_64) OBF_PLATFORM=linux-amd64 ;; \
        aarch64) OBF_PLATFORM=linux-arm64 ;; \
        *) echo "unsupported arch for obfuscating toolchain: $ARCH" >&2; exit 1 ;; \
    esac && \
    curl -fsSL -o "/tmp/rust-obfuscation-${OBF_PLATFORM}.tar.gz" \
        "${OBF_REPO_BASE}/${OBF_TAG}/rust-obfuscation-${OBF_PLATFORM}.tar.gz" && \
    curl -fsSL -o "/tmp/rust-obfuscation-${OBF_PLATFORM}.tar.gz.sha256" \
        "${OBF_REPO_BASE}/${OBF_TAG}/rust-obfuscation-${OBF_PLATFORM}.tar.gz.sha256" && \
    cd /tmp && sha256sum -c "rust-obfuscation-${OBF_PLATFORM}.tar.gz.sha256" && \
    mkdir -p /opt/llvm-obf && \
    tar -xzf "/tmp/rust-obfuscation-${OBF_PLATFORM}.tar.gz" -C /opt/llvm-obf && \
    rm -f /tmp/rust-obfuscation-${OBF_PLATFORM}.tar.gz* && \
    ln -s /opt/llvm-obf/rust-obfuscation-*-linux-* /opt/llvm-obf/current && \
    chmod -R a+w /opt/llvm-obf
# Stable paths for the build script (the `current` symlink hides the
# commit-hashed inner directory name)
ENV OBF_RUSTC=/opt/llvm-obf/current/rust-toolchain/bin/rustc

# Obfuscating clang from the same release (all codegen backends, carries the
# -sobf/-sub/-split/-bcf/-fla C passes) - used for compiling object files in
# downstream tooling (e.g. COFF/BOF loaders) and general C tooling.
RUN ARCH=$(uname -m) && \
    case "$ARCH" in \
        x86_64) OBF_PLATFORM=linux-amd64 ;; \
        aarch64) OBF_PLATFORM=linux-arm64 ;; \
        *) echo "unsupported arch for obfuscating clang: $ARCH" >&2; exit 1 ;; \
    esac && \
    curl -fsSL -o "/tmp/llvm-obfuscator-${OBF_TAG}-${OBF_PLATFORM}.zip" \
        "${OBF_REPO_BASE}/${OBF_TAG}/llvm-obfuscator-${OBF_TAG}-${OBF_PLATFORM}.zip" && \
    curl -fsSL -o "/tmp/llvm-obfuscator-${OBF_TAG}-${OBF_PLATFORM}.zip.sha256" \
        "${OBF_REPO_BASE}/${OBF_TAG}/llvm-obfuscator-${OBF_TAG}-${OBF_PLATFORM}.zip.sha256" && \
    cd /tmp && sha256sum -c "llvm-obfuscator-${OBF_TAG}-${OBF_PLATFORM}.zip.sha256" && \
    mkdir -p /opt/llvm-obf-clang && \
    unzip -q "/tmp/llvm-obfuscator-${OBF_TAG}-${OBF_PLATFORM}.zip" -d /opt/llvm-obf-clang && \
    rm -f /tmp/llvm-obfuscator-${OBF_TAG}-${OBF_PLATFORM}.zip* && \
    ln -s /opt/llvm-obf-clang/llvm-obfuscator-* /opt/llvm-obf-clang/current && \
    chmod -R a+w /opt/llvm-obf-clang
ENV OBF_CLANG=/opt/llvm-obf-clang/current/bin/clang
