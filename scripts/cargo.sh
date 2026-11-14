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
    # cc-rs build scripts (tree-sitter grammars) archive static libs; the
    # system has no ar, so point it at the toolchain's.
    if [ -x "$TC/bin/x86_64-linux-ar" ]; then
        export AR="$TC/bin/x86_64-linux-ar"
        export AR_x86_64_unknown_linux_gnu="$AR"
        case ":$PATH:" in
            *":$TC/bin:"*) ;;
            *) export PATH="$TC/bin:$PATH" ;;
        esac
    fi
    # The Bootlin sysroot glibc is older than the runtime glibc; allow undefined
    # symbols from host shared libraries at link time (they resolve at runtime).
    export RUSTFLAGS="-Clink-arg=-Wl,--allow-shlib-undefined"
    # Always use the pkg-config shim on Linux: a real pkg-config emits system
    # library paths (e.g. -L/usr/lib64) that the Bootlin cross-GCC rejects as
    # unsafe in cross-compilation, while the shim keeps link paths inside $HOME
    # and resolves the fontconfig runtime library on any host.
    SHIM="$HOME/.local/share/campy-sandbox/bin/campy-pkg-config"
    [ -x "$SHIM" ] && export PKG_CONFIG="$SHIM"
    # The linker may emit -lfontconfig before its -L search path, so make the
    # runtime fontconfig dev symlink discoverable through GCC's search path too.
    SANDBOX_LIB="$HOME/.local/share/campy-sandbox/lib"
    if [ -e "$SANDBOX_LIB/libfontconfig.so" ]; then
        export LIBRARY_PATH="$SANDBOX_LIB${LIBRARY_PATH:+:$LIBRARY_PATH}"
    fi
fi

exec cargo "$@"
