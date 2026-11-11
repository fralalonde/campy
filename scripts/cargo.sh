#!/usr/bin/env bash
# Build Cargo targets with the project toolchain when it is installed.
# The system clang/mold toolchain produces a NIF requiring a newer glibc than
# this runtime (and some sandboxes) provide.
set -euo pipefail

TC="${CAMPY_TOOLCHAIN:-$HOME/.local/toolchain/x86-64--glibc--stable-2025.08-1}"
GCC="$TC/bin/x86_64-linux-gcc"
GXX="$TC/bin/x86_64-linux-g++"

if [ -x "$GCC" ]; then
    export CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER="$GCC"
    export CC="$GCC"
    [ -x "$GXX" ] && export CXX="$GXX"
    # The Bootlin sysroot glibc is older than the runtime glibc; allow undefined
    # symbols from host shared libraries at link time (they resolve at runtime).
    export RUSTFLAGS="-Clink-arg=-Wl,--allow-shlib-undefined"
    SHIM="$HOME/.local/share/campy-sandbox/bin/campy-pkg-config"
    [ -x "$SHIM" ] && export PKG_CONFIG="$SHIM"
fi

exec cargo "$@"
