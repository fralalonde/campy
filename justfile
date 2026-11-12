set shell := ["bash", "-euo", "pipefail", "-c"]

root := justfile_directory()

default:
    @just --list

# Check the locally installed toolchain.
doctor:
    python scripts/workspace.py doctor

build-rust:
    ./scripts/cargo.sh build --manifest-path rust/Cargo.toml --locked

stage-nif: build-rust
    python scripts/workspace.py stage-nif

build-gleam:
    python scripts/workspace.py gleam build

# Build both subroots and install the development NIF into the bridge package.
build: stage-nif build-gleam

# Remove Rust/Gleam build artifacts and the staged development NIF.
clean:
    ./scripts/cargo.sh clean --manifest-path rust/Cargo.toml
    python scripts/workspace.py clean

# Open the native Gleam/BEAM IDE host (Linux or Windows Winit).
run: build
    python scripts/workspace.py run

# Rebuild and restart the IDE after successful Gleam source changes.
dev: build
    python scripts/workspace.py dev

# Generate the current search-box UI without hand-editing Slint.
generate: build
    python scripts/workspace.py generate

# Render the IDE shell states (property/model updates, no reloads) to generated/.
snapshot-ide: build
    python scripts/workspace.py snapshot-ide

test: stage-nif
    ./scripts/cargo.sh test --manifest-path rust/Cargo.toml --locked
    python scripts/workspace.py gleam test

fmt:
    ./scripts/cargo.sh fmt --manifest-path rust/Cargo.toml --all
    python scripts/workspace.py gleam format

fmt-check:
    ./scripts/cargo.sh fmt --manifest-path rust/Cargo.toml --all -- --check
    python scripts/workspace.py gleam format --check

check: fmt-check test


# Linux integration smoke; temporarily edits and restores the search-box fixture.
smoke-reload: build
    python scripts/smoke_reload.py

# Headless compiler/NIF bootstrap for CI and display-free verification.
smoke: build
    python scripts/workspace.py smoke

# Native rendering/input/lifecycle test; `just smoke-native x11` tests X11.
smoke-native backend="auto": build-gleam
    ./scripts/cargo.sh build --manifest-path rust/Cargo.toml --locked --features campy-bridge/ui-testing
    python scripts/workspace.py stage-nif
    python scripts/smoke_native.py {{backend}}
