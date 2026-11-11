set shell := ["bash", "-euo", "pipefail", "-c"]

root := justfile_directory()

default:
    @just --list

# Check the locally installed toolchain.
doctor:
    python3 scripts/workspace.py doctor

build-rust:
    cargo build --manifest-path rust/Cargo.toml --locked

stage-nif: build-rust
    python3 scripts/workspace.py stage-nif

build-gleam:
    python3 scripts/workspace.py gleam build

# Build both subroots and install the development NIF into the bridge package.
build: stage-nif build-gleam

# Open the native Gleam/BEAM search-box host (Linux Winit).
run: build
    python3 scripts/workspace.py run

# Rebuild and restart the IDE after successful Gleam source changes.
dev: build
    python3 scripts/workspace.py dev

# Generate the current search-box UI without hand-editing Slint.
generate: build
    python3 scripts/workspace.py generate

# Render the IDE shell states (property/model updates, no reloads) to generated/.
snapshot-ide: build
    python3 scripts/workspace.py snapshot-ide

test: stage-nif
    cargo test --manifest-path rust/Cargo.toml --locked
    python3 scripts/workspace.py gleam test

fmt:
    cargo fmt --manifest-path rust/Cargo.toml --all
    python3 scripts/workspace.py gleam format

fmt-check:
    cargo fmt --manifest-path rust/Cargo.toml --all -- --check
    python3 scripts/workspace.py gleam format --check

check: fmt-check test


# Linux integration smoke; temporarily edits and restores the search-box fixture.
smoke-reload: build
    python3 scripts/smoke_reload.py

# Headless compiler/NIF bootstrap for CI and display-free verification.
smoke: build
    python3 scripts/workspace.py smoke

# Native rendering/input/lifecycle test; `just smoke-native x11` tests X11.
smoke-native backend="auto": build-gleam
    cargo build --manifest-path rust/Cargo.toml --locked --features campy-bridge/ui-testing
    python3 scripts/workspace.py stage-nif
    python3 scripts/smoke_native.py {{backend}}
