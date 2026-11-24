//! Masonry (Xilem's retained widget layer) benchmark.
//!
//! Masonry is the layer a campy bridge would actually drive: retained
//! widgets, imperative `WidgetMut` edits, action-based callbacks. Xilem's
//! reactive view layer has no headless driver at 0.4, so these numbers are
//! the retained-layer costs that xilem sits on top of; xilem adds a
//! view-diff on top of the rebuild-heavy scenarios.
//!
//! Headless via `masonry_testing::TestHarness`: real layout/text/paint
//! passes, no window system. Two raster modes:
//!
//!   default         -> `render()` rasterizes with Vello on the CPU
//!                      (`use_cpu: true`), the harness's own test path.
//!                      Production xilem uses Vello on wgpu instead.
//!   `-passes` suffix -> `SKIP_RENDER_TESTS=1`: passes + Vello scene
//!                      encoding, raster skipped. Comparable to the zgui
//!                      capture-renderer methodology.
//!
//!   construct -> build the 64-control form + first frame
//!   sparse    -> one Label text edit + passes + paint
//!   wide      -> full rebuild of a 1000-row list (masonry 0.4 has no
//!                incremental list replace; worst case, not virtualized)
//!   reload    -> replace the window contents: new tree + frame
//!   click     -> pointer press/release on a Button + passes + paint,
//!                action observed via pop_action (what xilem wraps)
//!
//! NOTE: every scenario that says "fresh harness" pays a per-harness wgpu
//! context + Vello CPU renderer setup that a long-lived app pays once.
//! Masonry 0.4 exposes no public in-place root replacement, which is
//! itself a finding for campy's reload story.

use std::time::Instant;

use masonry::core::{NewWidget, PointerButton, Widget, WidgetId};
use masonry::kurbo::Size;
use masonry_testing::{TestHarness, TestHarnessParams, widget_ids};
use masonry::theme::default_property_set;
use masonry::widgets::{Button, ButtonPress, Checkbox, Flex, Label, TextInput};

const ROWS: usize = 16; // 4 controls per row => 64 controls
const LIST_ROWS: usize = 1000;

/// A campy-style form row: Label + TextInput + Button + Checkbox.
fn form(btn_id: WidgetId, lbl_id: WidgetId) -> NewWidget<impl Widget> {
    let mut column = Flex::column();
    for row in 0..ROWS {
        let line = Flex::row()
            .with_child(if row == 8 {
                Label::new(format!("Label {row}")).with_id(lbl_id)
            } else {
                Label::new(format!("Label {row}")).with_auto_id()
            })
            .with_child(TextInput::new(&format!("edit {row}")).with_auto_id())
            .with_child(if row == 8 {
                Button::new(Label::new(format!("Button {row}")).with_auto_id()).with_id(btn_id)
            } else {
                Button::new(Label::new(format!("Button {row}")).with_auto_id()).with_auto_id()
            })
            .with_child(Checkbox::new(false, format!("Check {row}")).with_auto_id());
        column = column.with_child(line.with_auto_id());
    }
    column.with_auto_id()
}

/// A non-virtualized 1000-row list (masonry 0.4 worst case).
fn list_form() -> NewWidget<impl Widget> {
    let mut column = Flex::column();
    for row in 0..LIST_ROWS {
        column = column.with_child(Label::new(format!("Item {row}")).with_auto_id());
    }
    column.with_auto_id()
}

fn params() -> TestHarnessParams {
    let mut params = TestHarnessParams::DEFAULT;
    params.window_size = Size::new(800.0, 700.0);
    params
}

fn stats(samples: &mut Vec<u128>) -> (u128, u128, u128) {
    samples.sort_unstable();
    let pick = |q: f64| -> u128 {
        let idx = ((samples.len() as f64) * q).round() as usize;
        samples[idx.min(samples.len() - 1)]
    };
    (pick(0.5), pick(0.1), pick(0.9))
}

fn report(scenario: &str, samples: &mut Vec<u128>) {
    let (median, p10, p90) = stats(samples);
    println!("{scenario},{median},{p10},{p90},{}", samples.len());
}

fn main() {
    let scenario = std::env::args().nth(1).unwrap_or_else(|| "all".into());
    // In `-passes` mode, masonry skips the CPU raster inside `render`
    // (its own SKIP_RENDER_TESTS mechanism) but still runs the Vello
    // scene encoding, matching the zgui capture-renderer methodology.
    let passes_only = scenario.ends_with("-passes");
    let paint = !passes_only;
    if passes_only {
        // SAFETY: single-threaded bench process, set before any render.
        unsafe { std::env::set_var("SKIP_RENDER_TESTS", "1") };
    }
    let [btn_id, lbl_id] = widget_ids();

    let name = |short: &str| -> String {
        if passes_only { format!("{short}-passes") } else { short.to_string() }
    };
    let wants = |short: &str| -> bool {
        matches!(scenario.as_str(), "all" | "all-passes") || scenario == name(short)
    };

    if wants("construct") {
        let mut samples = Vec::new();
        for _ in 0..3 {
            // Warmup absorbs one-time Vello/wgpu setup in paint mode.
            let mut harness = TestHarness::create_with(
                default_property_set(),
                form(btn_id, lbl_id),
                params(),
            );
            let _ = harness.render();
        }
        for _ in 0..30 {
            let start = Instant::now();
            let mut harness = TestHarness::create_with(
                default_property_set(),
                form(btn_id, lbl_id),
                params(),
            );
            let image = harness.render();
            samples.push(start.elapsed().as_micros());
            if paint {
                assert_eq!((image.width(), image.height()), (800, 700));
            }
            drop(harness);
        }
        report(&name("construct"), &mut samples);
    }

    if wants("sparse") {
        let mut harness = TestHarness::create_with(
            default_property_set(),
            form(btn_id, lbl_id),
            params(),
        );
        let _ = harness.render();
        let mut samples = Vec::new();
        for i in 0..300 {
            let text = format!("Count {i}");
            let start = Instant::now();
            harness.edit_widget_with_id(lbl_id, move |mut widget| {
                let mut label = widget.downcast::<Label>();
                Label::set_text(&mut label, text);
            });
            let image = harness.render();
            samples.push(start.elapsed().as_micros());
            if paint {
                assert_eq!((image.width(), image.height()), (800, 700));
            }
            let _ = i;
        }
        report(&name("sparse"), &mut samples);
    }

    if wants("wide") {
        let mut samples = Vec::new();
        for _ in 0..20 {
            let start = Instant::now();
            // Full list rebuild: masonry 0.4 has no SetModel equivalent, so
            // replacing the data means replacing the widgets.
            let mut harness =
                TestHarness::create_with(default_property_set(), list_form(), params());
            let _ = harness.render();
            samples.push(start.elapsed().as_micros());
        }
        report(&name("wide"), &mut samples);
    }

    if wants("reload") {
        let mut samples = Vec::new();
        for _ in 0..30 {
            // Window content replacement: masonry 0.4 offers no in-place root
            // swap, so a reload is a fresh tree on a fresh harness.
            let start = Instant::now();
            let mut harness = TestHarness::create_with(
                default_property_set(),
                form(btn_id, lbl_id),
                params(),
            );
            let _ = harness.render();
            samples.push(start.elapsed().as_micros());
        }
        report(&name("reload"), &mut samples);
    }

    if wants("click") {
        let mut harness = TestHarness::create_with(
            default_property_set(),
            form(btn_id, lbl_id),
            params(),
        );
        let _ = harness.render();
        let mut hits = 0u64;
        let mut samples = Vec::new();
        for _ in 0..300 {
            let start = Instant::now();
            harness.mouse_move_to(btn_id);
            harness.mouse_button_press(PointerButton::Primary);
            harness.mouse_button_release(PointerButton::Primary);
            let action = harness.pop_action::<ButtonPress>();
            let _ = harness.render();
            samples.push(start.elapsed().as_micros());
            assert!(action.is_some(), "the click raised the button action");
            hits += 1;
        }
        assert_eq!(hits, 300);
        report(&name("click"), &mut samples);
    }
}
