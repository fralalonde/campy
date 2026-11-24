#!/usr/bin/env bash
# Collects build metrics and scenario timings for all three benches.
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p results
log() { printf '%s\n' "$*" | tee -a results/metrics.txt; }

: > results/metrics.txt
log "=== campy toolkit shootout $(date -Iseconds) ==="
log "rustc $(rustc --version), $(nproc) cores"

for crate in bench-slint bench-xilem bench-zgui; do
  log ""
  log "--- $crate ---"

  # Cold release build in an isolated target dir.
  dir="target/cold-$crate"
  rm -rf "$dir"
  start=$(date +%s.%N)
  CARGO_TARGET_DIR="$dir" cargo build --release -p "$crate" --quiet
  end=$(date +%s.%N)
  cold=$(awk "BEGIN { printf \"%.1f\", $end - $start }")
  log "cold_release_build_s,$cold"

  # Incremental rebuild after touching the binary's sources.
  touch "$crate/src/main.rs"
  start=$(date +%s.%N)
  CARGO_TARGET_DIR="$dir" cargo build --release -p "$crate" --quiet
  end=$(date +%s.%N)
  inc=$(awk "BEGIN { printf \"%.1f\", $end - $start }")
  log "incremental_release_build_s,$inc"

  # Dependency count and binary sizes.
  deps=$(cargo tree -p "$crate" --prefix none --quiet | wc -l)
  log "dependency_crates,$deps"
  bin="$dir/release/$crate"
  size=$(stat -c%s "$bin")
  cp "$bin" "/tmp/opencode/$crate.stripped" && strip "/tmp/opencode/$crate.stripped"
  ssize=$(stat -c%s "/tmp/opencode/$crate.stripped")
  log "binary_bytes,$size"
  log "binary_stripped_bytes,$ssize"
done

log ""
log "=== scenarios (median,p10,p90 µs) ==="
./target/release/bench-slint all   | tee -a results/metrics.txt
./target/release/bench-xilem all  | tee -a results/metrics.txt
./target/release/bench-xilem all-passes | tee -a results/metrics.txt
./target/release/bench-zgui all   | tee -a results/metrics.txt
log ""
log "done."
