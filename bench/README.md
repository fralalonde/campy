# Toolkit shootout: Slint vs zgui vs Xilem/Masonry for campy

Benchmarks and tests backing the toolkit evaluation for replacing Slint in
campy. Three sibling crates implement the **same logical form** — 16 rows ×
(label, edit, button, checkbox) = 64 controls, plus a 1000-row list — and
run the **same bridge-shaped scenarios** that campy's NIF performs today:

| Scenario | campy operation it models |
|---|---|
| `compile` | `validate_ui` / the compile half of `LoadUi` (F6) |
| `construct` | create + show + first rendered frame of a designed form |
| `sparse` | `SetText` property publish + one frame (F7-style live update) |
| `wide` | `SetModel` with a fresh 1000-row model + one frame |
| `reload` | full `LoadUi`: compile/rebuild the form and swap it in (F6) |
| `click` | injected pointer events through the widget to the handler |

Each binary prints `scenario,median_us,p10_us,p90_us,iters`.

## Methodology

* **bench-slint** — `slint-interpreter` **=1.18.1**, the exact pin campy
  uses, on Slint's testing backend: headless, **software renderer**
  (campy's production renderer), mocked time, no event loop. A frame is
  forced with `Window::take_snapshot()`. Numbers therefore include the
  full CPU raster of the 800×700 window, which is what campy's
  software-rendered production path actually pays.
* **bench-zgui** — zgui **0.1.0** on `zgui-platform-headless`: the real
  frame loop (dispatch → reactive flush → Stylo restyle → Cephal layout →
  paint) with a capture renderer, the same methodology behind zgui's
  published cost model. The wgpu/Vello draw is **excluded** (production
  adds it; zgui's own on-screen measurements put the gallery startup at
  216–247 ms vs 112 ms headless). Signals are created in the app scope and
  driven from the bench thread, exactly how a NIF bridge would poke the
  document.
* **bench-xilem** — masonry **0.4.0** (xilem's retained widget layer —
  xilem has no headless application driver) via
  `masonry_testing::TestHarness`: real passes, **Vello CPU raster**
  (`use_cpu: true`) in `render()`, plus a `-passes` mode that uses
  masonry's own `SKIP_RENDER_TESTS` mechanism to skip raster while keeping
  the scene encoding — comparable to the zgui capture methodology.
  Production xilem renders with Vello on wgpu (GPU), not the CPU fallback
  measured here.

Cross-toolkit comparability caveats are therefore explicit:

1. Raster coverage differs: slint includes its production software raster;
   zgui excludes raster entirely; xilem's default numbers include a **test
   fallback** CPU raster (production uses GPU), so the `-passes` numbers
   are the fair "pipeline work" comparison for xilem.
2. Every "fresh harness/instance" scenario includes per-iteration init
   (fonts, wgpu context in xilem's paint mode) that a long-lived app pays
   once; warmups absorb the first-run costs and medians are reported.
3. The list scenario is a full 1000-row data replace: virtualized in slint
   (`ListView`) and zgui (`VirtualList`, viewport-mounted), a full widget
   rebuild in masonry (no incremental list at 0.4).

## Results

`results/metrics.txt` holds the raw run. Rustc 1.100, 16 cores, 2026-11-23.
All timings are medians; the form is 64 controls in an 800×700 (slint,
xilem) / 1024×768 (zgui) window.

### Build & footprint (release)

| | bench-slint (=1.18.1) | bench-xilem (masonry 0.4) | bench-zgui (0.1) |
|---|---:|---:|---:|
| cold build | 81.7 s | 74.6 s | 200.0 s |
| incremental (touch bin) | 2.2 s | 1.8 s | 2.9 s |
| dependency crates | 460 | 350 | 1451 |
| binary (stripped) | 19.3 MB | 10.3 MB | 25.7 MB |

The zgui dependency tree includes Servo's Stylo, wgpu, and Vello, hence the
cold-build time and crate count; incremental rebuilds are comparable
(~2–3 s).

### Scenario medians (µs)

| Scenario (campy op) | slint¹ | xilem passes² | xilem +CPU raster³ | zgui⁴ |
|---|---:|---:|---:|---:|
| `compile` (validate_ui) | 44,420 | — | — | — |
| `construct` (form + first frame) | 9,247 | 1,811 | 160,829 | 28,653 |
| `sparse` (SetText + frame) | 6,306 | 55 | 37,600 | 92 |
| `wide` (1000-row SetModel) | 6,886 | 11,153 | 186,594 | 881 |
| `reload` (F6 LoadUi) | 60,862 | 890 | 154,484 | 13,747 |
| `click` (pointer → handler) | 472 | 46 | 35,120 | 8 |

¹ slint includes the **full 800×700 software raster** — campy's production
renderer. A live window additionally benefits from dirty-region tracking,
so production sparse updates cost less than the snapshot-forced frame here.
`click` excludes the repaint entirely (events + callback only).

² masonry `-passes`: rewrite/layout passes + Vello scene encoding, raster
skipped via masonry's own `SKIP_RENDER_TESTS`. The fair "pipeline work"
column.

³ masonry default `render()`: Vello **CPU** raster — masonry's *test
fallback*, not its production path (production is Vello on wgpu/GPU).
Included for completeness; do not compare it against the other columns
except as "what the TestHarness costs".

⁴ zgui headless with the capture renderer: real flush/restyle/layout/paint
stages, wgpu/Vello draw excluded. zgui's own published on-screen
measurements (their cost model): gallery startup 216–247 ms on device vs
112 ms headless; a class-toggle click 10.8 µs — consistent with the 92 µs
text-change and 8 µs click measured here.

Reading notes:

* **Sparse updates**: zgui and masonry do damage-restricted work measured in
  tens of microseconds. Slint pays a full-frame CPU raster in this
  configuration (~6.3 ms at 800×700); that is the real cost of campy's
  software-renderer choice, not an artifact.
* **Wide updates**: virtualization dominates. Slint (`ListView`) and zgui
  (`VirtualList`) mount only the viewport; masonry 0.4 has no incremental
  list, so a data replace is a 1000-widget rebuild (11.2 ms passes).
* **Reload**: Slint's F6 is dominated by the interpreter compile (~44 ms of
  the ~61 ms). zgui's view rebuild from data is ~13.7 ms with no compile
  step. Masonry's tree rebuild is the cheapest (~0.9 ms passes) but there is
  no public in-place root replacement to hang a reload protocol on.
* Every scenario asserts behavior (handlers fired, snapshots sized,
  actions raised), so the numbers double as integration tests.

## Running

```sh
./run.sh                       # build metrics + all scenarios
./target/release/bench-slint sparse
./target/release/bench-xilem all-passes
./target/release/bench-zgui reload
```

See `samples.md` for the code samples that ground the analysis: the same
form in all three toolkits, hot-reload patterns, and the NIF-thread
question.
