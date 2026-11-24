//! zgui benchmark over the headless platform.
//!
//! Runs the real frame loop (dispatch -> reactive flush -> Stylo restyle ->
//! Cephal layout -> paint) on `zgui-platform-headless` with a capture
//! renderer, the same methodology behind zgui's published cost model. What
//! is excluded versus the shipped app is the wgpu/Vello draw itself.
//!
//! The form mirrors the Slint bench: 16 rows of label + field + control +
//! checkbox (64 controls), plus a virtualized 1000-row list.
//!
//!   construct -> fresh app: fonts, sheet parse, document build, first frame
//!   sparse    -> one label signal write + one settled frame
//!   wide      -> VirtualList row data replaced (1000 rows, viewport-mounted)
//!   reload    -> suspend + resume: every view rebuilt from current data,
//!                the in-process reload primitive a bridge would use
//!   click     -> surface pointer events to a control + settled frame
//!
//! Signals are created inside the app's reactive scope during the view
//! build and driven from this thread between frames, which is how a
//! NIF-driven bridge would poke the document.

use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::sync::Arc;
use std::time::{Duration, Instant};

use zgui::geom::{Css, CssPx, DevicePx, Point, Size};
use zgui::platform::{Surface, SurfaceEvent};
use zgui::elements::{column, control, field, row, text};
use zgui::prelude::*;
use zgui::render::{RenderTarget, Renderer};
use zgui::runtime::{AppError, Runtime};
use zgui::view::{AnyView, events};
use zgui_platform_headless::Harness;
use zgui_testkit_scene::CaptureRenderer;
use zgui_ui::prelude::*;
use zgui::vocab::{Modifiers, PointerAction, PointerEvent, Timestamp};

const ROWS: usize = 16; // 4 controls per row => 64 controls
const LIST_ROWS: usize = 1000;
const WINDOW_W: f32 = 1024.0;
const WINDOW_H: f32 = 768.0;

/// Everything the bench thread and the view build share.
struct Shared {
    /// Initial label text per row; mutated for the reload scenario.
    label_texts: RefCell<Vec<String>>,
    /// Button captions per row.
    buttons: RefCell<Vec<String>>,
    /// The live label signal of the current build, per row.
    labels: RefCell<Vec<Option<RwSignal<String>>>>,
    /// The live list-data signal of the current build.
    items: RefCell<Option<RwSignal<Vec<String>>>>,
    clicks: Cell<u64>,
}

/// A capture renderer factory: records the display list, draws nothing.
fn capture(
    _surface: &Arc<dyn Surface>,
    target: RenderTarget,
) -> Result<Box<dyn Renderer>, AppError> {
    let mut renderer = CaptureRenderer::new();
    renderer.configure(target);
    Ok(Box::new(renderer))
}

const SHEET: &str = css!(
    ".form-row { gap: 16px; align-items: center; padding: 4px 8px; }
     .form-row text { width: 200px; height: 26px; }
     .form-row field { width: 180px; height: 26px; }
     .form-row control { width: 110px; height: 26px; }
     .list { height: 96px; border: 1px solid #888; }"
);

/// The form: built from the descriptor data on every (re)build, the way a
/// generated-view or bridge-driven document would be.
fn build_view(shared: Rc<Shared>) -> impl IntoView {
    let mut labels = shared.labels.borrow_mut();
    let rows: Vec<AnyView> = (0..ROWS)
        .map(|idx| {
            let shared = shared.clone();
            let label = RwSignal::new(shared.label_texts.borrow()[idx].clone());
            let button = shared.buttons.borrow()[idx].clone();
            labels[idx] = Some(label.clone());
            row()
                .class("form-row")
                .child(text().child(move || label.get()))
                .child(field())
                .child(
                    control()
                        .class(format!("btn-{idx}"))
                        .on(events::CLICK, move |_| {
                            shared.clicks.set(shared.clicks.get() + 1);
                        })
                        .child(button),
                )
                .child(view! { Checkbox() })
        })
        .map(AnyView::new)
        .collect();
    let items = RwSignal::new(
        (0..LIST_ROWS).map(|i| format!("Item {i}")).collect::<Vec<_>>(),
    );
    *shared.items.borrow_mut() = Some(items.clone());
    let list = view! {
        VirtualList(
            count = RwSignal::new_local(LIST_ROWS),
            row_size = 24.0,
            class = "list",
            label = "Rows",
            row = move |index: usize| {
                let items = items.clone();
                view! { text {{move || items.get()[index].clone()}} }
            },
        )
    };
    column().children(rows).child(list)
}

fn open_harness(shared: &Rc<Shared>) -> Harness<Runtime> {
    let shared = shared.clone();
    let app = app()
        .with_title("campy bench")
        .with_size(WINDOW_W, WINDOW_H)
        .with_stylesheet(SHEET)
        .with_renderer(Box::new(capture));
    let handler = app
        .into_handler(move || build_view(shared.clone()))
        .expect("the reactive runtime installs");
    let runtime = handler.into_runtime();
    let mut harness = Harness::new(runtime);
    harness.deliver_to_first(SurfaceEvent::Resized(Size::new(
        DevicePx(WINDOW_W),
        DevicePx(WINDOW_H),
    )));
    harness.settle(64);
    harness
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

fn pointer(action: PointerAction, at: Point<CssPx, Css>, time: Timestamp) -> SurfaceEvent {
    SurfaceEvent::Pointer {
        action,
        event: PointerEvent::mouse(at),
        modifiers: Modifiers::NONE,
        timestamp: time,
    }
}

fn main() {
    let scenario = std::env::args().nth(1).unwrap_or_else(|| "all".into());
    let shared = Rc::new(Shared {
        label_texts: RefCell::new((0..ROWS).map(|r| format!("Label {r}")).collect()),
        buttons: RefCell::new((0..ROWS).map(|r| format!("Button {r}")).collect()),
        labels: RefCell::new(vec![None; ROWS]),
        items: RefCell::new(None),
        clicks: Cell::new(0),
    });

    if matches!(scenario.as_str(), "construct" | "all") {
        let mut samples = Vec::new();
        for _ in 0..3 {
            // Warmup absorbs one-time font enumeration and caches.
            let _ = open_harness(&shared);
        }
        for _ in 0..30 {
            let start = Instant::now();
            let harness = open_harness(&shared);
            samples.push(start.elapsed().as_micros());
            assert!(!harness.app().windows().is_empty());
        }
        report("construct", &mut samples);
    }

    if matches!(scenario.as_str(), "sparse" | "all") {
        let mut harness = open_harness(&shared);
        let label = shared.labels.borrow()[8].clone().expect("built");
        let mut samples = Vec::new();
        for i in 0..300 {
            let start = Instant::now();
            label.set(format!("Count {i}"));
            harness.settle(16);
            samples.push(start.elapsed().as_micros());
        }
        report("sparse", &mut samples);
    }

    if matches!(scenario.as_str(), "wide" | "all") {
        let mut harness = open_harness(&shared);
        let items = shared.items.borrow().clone().expect("built");
        let mut samples = Vec::new();
        for i in 0..50 {
            let start = Instant::now();
            // Replace the whole list data: mounted rows rebuild through the
            // signal read, off-screen rows never exist.
            items.set((0..LIST_ROWS).map(|r| format!("Item {r} of {i}")).collect());
            harness.settle(16);
            samples.push(start.elapsed().as_micros());
        }
        report("wide", &mut samples);
    }

    if matches!(scenario.as_str(), "reload" | "all") {
        let mut harness = open_harness(&shared);
        let mut samples = Vec::new();
        for i in 0..20 {
            // New designer data first, then the rebuild the bridge would ask
            // for: suspend drops every surface, resume recreates them and
            // rebuilds the views through the same closure.
            shared.buttons.borrow_mut()[8] = format!("Button {i}");
            shared.label_texts.borrow_mut()[8] = format!("Label {i}");
            let start = Instant::now();
            harness.suspend();
            harness.resume();
            harness.settle(64);
            samples.push(start.elapsed().as_micros());
        }
        report("reload", &mut samples);
    }

    if matches!(scenario.as_str(), "click" | "all") {
        let mut harness = open_harness(&shared);
        let rect = harness.app().windows()[0]
            .box_with_class("btn-8")
            .expect("the control laid out");
        let centre = Point::new(
            CssPx(rect.origin.x.0 + rect.size.width.0 / 2.0),
            CssPx(rect.origin.y.0 + rect.size.height.0 / 2.0),
        );
        let before = shared.clicks.get();
        let mut samples = Vec::new();
        for i in 0..300 {
            let time = Timestamp::ORIGIN + Duration::from_millis(700 * i as u64);
            let start = Instant::now();
            harness.deliver_to_first(pointer(PointerAction::Moved, centre, time));
            harness.deliver_to_first(pointer(PointerAction::Pressed, centre, time));
            harness.deliver_to_first(pointer(PointerAction::Released, centre, time));
            harness.settle(8);
            samples.push(start.elapsed().as_micros());
        }
        assert!(shared.clicks.get() > before, "the click reached the handler");
        report("click", &mut samples);
    }
}
