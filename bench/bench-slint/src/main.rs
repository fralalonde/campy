//! Slint interpreter benchmark mirroring campy's bridge operations.
//!
//! Runs headlessly on Slint's testing backend (software renderer, no event
//! loop, no window system). Every scenario corresponds to an operation the
//! campy NIF actually performs:
//!
//!   compile   -> `validate_ui` / the compile half of `LoadUi` (F6)
//!   construct -> create + show + first rendered frame of a designed form
//!   sparse    -> `SetText` property publish + one frame (F7-style update)
//!   wide      -> `SetModel` with a fresh 1000-row model + one frame
//!   reload    -> full `LoadUi`: compile + create + swap-in (F6)
//!   click     -> injected pointer event through the widget to the callback
//!
//! The generated form matches campy's live-preview emitter: absolutely
//! positioned standard widgets plus one `ListView`.

use std::cell::Cell;
use std::rc::Rc;
use std::time::Instant;

use slint::platform::{PointerEventButton, WindowEvent};
use slint::{ComponentHandle, LogicalPosition, LogicalSize, ModelRc, VecModel};
use slint_interpreter::{ComponentDefinition, CompilationResult, Compiler, DiagnosticLevel, Value};

const ROWS: usize = 16; // 4 controls per row => 64 controls
const ROW_H: f32 = 36.0;
const WIDTH: f32 = 800.0;
const HEIGHT: f32 = 700.0;
const LIST_ROWS: usize = 1000;

/// The .slint source for a campy-style form, as `campy_form/live_preview`
/// would emit it: absolute geometry, standard widgets, one list model.
fn form_source(rows: usize) -> String {
    let mut source = String::from(
        "import { Button, CheckBox, LineEdit, ListView } from \"std-widgets.slint\";\n\
         struct RowData { text: string }\n\
         export component CampyPreview inherits Window {\n\
         title: \"campy bench\";\n\
         preferred-width: 800px;\n\
         preferred-height: 700px;\n\
         callback event(string);\n\
         in-out property <[RowData]> rows-model: [];\n\
         ListView { y: 600px; height: 96px; for item in root.rows-model: Rectangle { height: 24px; Text { text: item.text; } } }\n",
    );
    for row in 0..rows {
        let y = row as f32 * ROW_H;
        source.push_str(&format!(
            "in-out property <string> label-{row}: \"Label {row}\";\n\
             Text {{ x: 8px; y: {y}px; text: root.label-{row}; }}\n\
             LineEdit {{ x: 220px; y: {y}px; width: 180px; height: 30px; text: \"edit {row}\"; }}\n\
             Button {{ x: 430px; y: {y}px; width: 110px; height: 32px; text: \"Button {row}\"; \
                 clicked => {{ root.event(\"btn-{row}\"); }} }}\n\
             CheckBox {{ x: 560px; y: {y}px; text: \"Check {row}\"; }}\n"
        ));
    }
    source.push_str("}\n");
    source
}

/// campy-renderer's compile: a fresh interpreter compiler per call.
fn compile(source: &str) -> CompilationResult {
    let compiler = Compiler::default();
    let result = spin_on::spin_on(
        compiler.build_from_source(source.into(), "campy-bench.slint".into()),
    );
    let errors: Vec<String> = result
        .diagnostics()
        .filter(|d| d.level() == DiagnosticLevel::Error)
        .map(|d| d.to_string())
        .collect();
    assert!(errors.is_empty(), "compile failed: {}", errors.join("\n"));
    result
}

fn definition(result: &CompilationResult) -> ComponentDefinition {
    result.component("CampyPreview").expect("component exported")
}

/// campy-renderer's load(): create, wire the generic callback sink, show,
/// and force the first frame with a snapshot (the software renderer draws).
fn make_instance(
    definition: &ComponentDefinition,
    clicks: &std::rc::Rc<std::cell::Cell<u64>>,
) -> slint_interpreter::ComponentInstance {
    let instance = definition.create().expect("instance");
    let clicks = clicks.clone();
    // The generic event channel: campy forwards every callback as a
    // session-tagged string payload.
    let sink = move |_args: &[Value]| {
        clicks.set(clicks.get() + 1);
        Value::Void
    };
    instance.set_callback("event", sink).expect("callback wired");
    instance.show().expect("shown");
    instance
        .window()
        .set_size(LogicalSize::new(WIDTH, HEIGHT));
    instance
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
    // Headless: the testing backend with the software rasterizer embedded,
    // mocked time, no event loop, no window system.
    i_slint_core::platform::set_platform(Box::new(
        i_slint_backend_testing::TestingBackend::new(
            i_slint_backend_testing::TestingBackendOptions {
                mock_time: true,
                threading: false,
                renderer_name: Some("software".into()),
            },
        ),
    ))
    .expect("testing platform installed");

    let scenario = std::env::args().nth(1).unwrap_or_else(|| "all".into());
    let source = form_source(ROWS);
    let clicks = Rc::new(Cell::new(0u64));

    if matches!(scenario.as_str(), "compile" | "all" | "reload") {
        // Compile-only (campy's `validate_ui`): fresh compiler per call.
        let mut samples = Vec::new();
        for i in 0..30 {
            let text = if i % 2 == 0 { source.clone() } else { source.replace("Label 0", "Label zero") };
            let start = Instant::now();
            let result = compile(&text);
            samples.push(start.elapsed().as_micros());
            drop(result);
        }
        report("compile", &mut samples);
    }

    if matches!(scenario.as_str(), "construct" | "all") {
        let result = compile(&source);
        let definition = definition(&result);
        let mut samples = Vec::new();
        for _ in 0..3 {
            // Warmup: first frame initializes fonts/renderer caches.
            let instance = make_instance(&definition, &clicks);
            let _ = instance.window().take_snapshot().expect("snapshot");
        }
        for i in 0..100 {
            let start = Instant::now();
            let instance = make_instance(&definition, &clicks);
            let snapshot = instance.window().take_snapshot().expect("snapshot");
            samples.push(start.elapsed().as_micros());
            assert_eq!(snapshot.width(), WIDTH as u32);
            let _ = i;
            instance.hide().expect("hidden");
        }
        report("construct", &mut samples);
    }

    if matches!(scenario.as_str(), "sparse" | "all") {
        let result = compile(&source);
        let instance = make_instance(&definition(&result), &clicks);
        let _ = instance.window().take_snapshot().expect("snapshot");
        let mut samples = Vec::new();
        for i in 0..300 {
            let start = Instant::now();
            instance
                .set_property(
                    "label-8",
                    Value::String(format!("Count {i}").into()),
                )
                .expect("property set");
            let _ = instance.window().take_snapshot().expect("snapshot");
            samples.push(start.elapsed().as_micros());
        }
        report("sparse", &mut samples);
    }

    if matches!(scenario.as_str(), "wide" | "all") {
        let result = compile(&source);
        let instance = make_instance(&definition(&result), &clicks);
        let _ = instance.window().take_snapshot().expect("snapshot");
        let mut samples = Vec::new();
        for i in 0..50 {
            // Build the wire model (campy builds WireValues on the BEAM side
            // and converts in the NIF; conversion is part of the cost).
            let start = Instant::now();
            let values: Vec<Value> = (0..LIST_ROWS)
                .map(|row| {
                    let mut item = slint_interpreter::Struct::default();
                    item.set_field("text".into(), Value::String(format!("Item {row} of {i}").into()));
                    Value::Struct(item)
                })
                .collect();
            instance
                .set_property(
                    "rows-model",
                    Value::Model(ModelRc::new(VecModel::from(values))),
                )
                .expect("model set");
            let _ = instance.window().take_snapshot().expect("snapshot");
            samples.push(start.elapsed().as_micros());
        }
        report("wide", &mut samples);
    }

    if matches!(scenario.as_str(), "reload" | "all") {
        // campy's F6 `LoadUi`: compile a changed form and swap it in.
        let mut samples = Vec::new();
        let mut instance = None;
        for i in 0..20 {
            let next = if i % 2 == 0 {
                source.clone()
            } else {
                source.replace("Button 8", &format!("Button {i}"))
            };
            let start = Instant::now();
            let result = compile(&next);
            let candidate = make_instance(&definition(&result), &clicks);
            let _ = candidate.window().take_snapshot().expect("snapshot");
            if let Some(old) = instance.replace(candidate) {
                old.hide().expect("hidden");
            }
            samples.push(start.elapsed().as_micros());
        }
        report("reload", &mut samples);
    }

    if matches!(scenario.as_str(), "click" | "all") {
        let result = compile(&source);
        let instance = make_instance(&definition(&result), &clicks);
        // campy activates the window before dispatching test input.
        instance
            .window()
            .dispatch_event_with_result(WindowEvent::WindowActiveChanged(true))
            .expect("activated");
        let _ = instance.window().take_snapshot().expect("snapshot");
        let before = clicks.get();
        let center = LogicalPosition::new(430.0 + 55.0, 8.0 * ROW_H + 16.0);
        let mut samples = Vec::new();
        for _ in 0..300 {
            let start = Instant::now();
            for event in [
                WindowEvent::PointerMoved { position: center },
                WindowEvent::PointerPressed { position: center, button: PointerEventButton::Left },
                WindowEvent::PointerReleased { position: center, button: PointerEventButton::Left },
            ] {
                instance
                    .window()
                    .dispatch_event_with_result(event)
                    .expect("dispatch");
            }
            samples.push(start.elapsed().as_micros());
        }
        assert!(clicks.get() > before, "the click reached the handler");
        report("click", &mut samples);
    }
}
