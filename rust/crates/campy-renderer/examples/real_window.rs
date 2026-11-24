//! Real-window smoke: the production path (winit + wgpu) on a live
//! desktop. Builds a form through the bridge, publishes updates, and
//! asserts the runtime stays alive for the duration. No input injection —
//! the surface-input story is owned by the headless suite; this proves
//! the event loop, device, and frame pipeline run for real.
//!
//! `cargo run -p campy-renderer --example real_window` (needs a display).

use std::sync::{Arc, Mutex};
use std::time::Duration;

use campy_renderer::sessions::{self, Command};
use campy_renderer::wire::{ControlDesc, Op, UiDocument};

fn form(theme: &str) -> UiDocument {
    UiDocument {
        title: "Campy real-window smoke".into(),
        width: 800.0,
        height: 600.0,
        theme: theme.into(),
        controls: vec![
            ControlDesc {
                id: 1,
                kind: "label".into(),
                text: "The production renderer, live.".into(),
                x: 24.0,
                y: 24.0,
                w: 420.0,
                h: 32.0,
                enabled: true,
                visible: true,
                props: vec![],
                children: vec![],
            },
            ControlDesc {
                id: 2,
                kind: "button".into(),
                text: "Click me".into(),
                x: 24.0,
                y: 80.0,
                w: 140.0,
                h: 40.0,
                enabled: true,
                visible: true,
                props: vec![],
                children: vec![],
            },
            ControlDesc {
                id: 3,
                kind: "code_editor".into(),
                text: "pub fn main() { Nil }".into(),
                x: 24.0,
                y: 150.0,
                w: 520.0,
                h: 220.0,
                enabled: true,
                visible: true,
                props: vec![(
                    "language".into(),
                    campy_renderer::wire::PropValue::Text("gleam".into()),
                )],
                children: vec![],
            },
        ],
    }
}

fn main() {
    let events: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
    let sink_events = events.clone();
    let sink = Arc::new(
        move |_session: u64, _generation: u64, kind: String, _payload: String| {
            sink_events.lock().unwrap().push(kind);
        },
    );
    let session = sessions::open(sink).expect("a session opens");

    session
        .submit(Command {
            generation: 1,
            op: Op::LoadUi(form("light")),
        })
        .expect("LoadUi enqueues");
    // The production drain rides the real clock; give it real time.
    std::thread::sleep(Duration::from_millis(600));
    assert!(
        events
            .lock()
            .unwrap()
            .iter()
            .any(|kind| kind == "ui-loaded"),
        "LoadUi applied on the real window: {:?}",
        events.lock().unwrap()
    );

    // A property publish and a reload (the F6 shape).
    session
        .submit(Command {
            generation: 1,
            op: Op::SetText {
                control: 1,
                value: "Updated live.".into(),
            },
        })
        .expect("SetText enqueues");
    session
        .submit(Command {
            generation: 2,
            op: Op::LoadUi(form("dark")),
        })
        .expect("reload enqueues");
    std::thread::sleep(Duration::from_millis(600));
    let loaded = events.lock().unwrap().len();
    assert!(
        loaded >= 2,
        "the reload applied: {loaded} events: {:?}",
        events.lock().unwrap()
    );

    // Stay up long enough for a human to see it, then check health.
    std::thread::sleep(Duration::from_secs(3));
    assert_eq!(
        sessions::active_sessions(),
        1,
        "the session is still registered"
    );
    let failures: Vec<String> = events
        .lock()
        .unwrap()
        .iter()
        .filter(|kind| kind.as_str() == "command-failed" || kind.as_str() == "runtime-failed")
        .cloned()
        .collect();
    assert!(
        failures.is_empty(),
        "no failures on the production path: {failures:?}"
    );
    println!(
        "real-window smoke ok: {} events, session healthy",
        events.lock().unwrap().len()
    );
}
