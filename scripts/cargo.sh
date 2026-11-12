#!/usr/bin/env bash
# Build Cargo targets with the project toolchain when it is installed.
# The system clang/mold toolchain produces a NIF requiring a newer glibc than
# this runtime (and some sandboxes) provide.
set -euo pipefail

case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        # Git Bash HOME can differ from the home used to install Cargo. Mixing
        # registry source paths in one target directory invalidates the cache.
        if [ -z "${CARGO_HOME:-}" ]; then
            CARGO_BIN="$(command -v cargo)"
            case "$CARGO_BIN" in
                */.cargo/bin/cargo|*/.cargo/bin/cargo.exe)
                    export CARGO_HOME="$(cygpath -w "$(dirname "$(dirname "$CARGO_BIN")")")"
                    ;;
            esac
        fi
        # Windows can deny rustc's final incremental-directory rename. A failed
        # session cannot be reused and its diagnostic is replayed on later runs.
        export CARGO_INCREMENTAL="${CARGO_INCREMENTAL:-0}"
        ;;
esac

TC="${CAMPY_TOOLCHAIN:-$HOME/.local/toolchain/x86-64--glibc--stable-2025.08-1}"
GCC="$TC/bin/x86_64-linux-gcc"
GXX="$TC/bin/x86_64-linux-g++"

if [ "$(uname -s)" = "Linux" ] && [ -x "$GCC" ]; then
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
