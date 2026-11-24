//! Headless bridge integration test (run with `cargo test -F ui-testing`).
//!
//! Drives the real UI thread, real zgui frame loop, and real command queue
//! exactly as the BEAM would: LoadUi a small form, publish a property,
//! click a button through injected surface events, and read state back.

#![cfg(feature = "ui-testing")]

use std::sync::{Arc, Mutex};
use std::time::Duration;

use campy_renderer::sessions::{self, Command};
use campy_renderer::testing;
use campy_renderer::wire::{ControlDesc, Op, PropValue, UiDocument};

#[derive(Clone, Default)]
struct Sink(Arc<Mutex<Vec<(u64, u64, String, String)>>>);

fn spawn_ui() -> (sessions::Session, Sink) {
    let sink = Sink::default();
    let events = sink.0.clone();
    let handle = Arc::new(
        move |session: u64, generation: u64, kind: String, payload: String| {
            events
                .lock()
                .unwrap()
                .push((session, generation, kind, payload));
        },
    );
    let session = sessions::open(handle).expect("a session opens");
    // The UI thread parks the headless harness shortly after; wait for it.
    for _ in 0..100 {
        if testing::test_pump(4).is_ok() {
            break;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    (session, sink)
}

fn form() -> UiDocument {
    UiDocument {
        title: "bench".into(),
        width: 800.0,
        height: 600.0,
        theme: "light".into(),
        controls: vec![
            ControlDesc {
                id: 1,
                kind: "label".into(),
                text: "Label 0".into(),
                x: 16.0,
                y: 16.0,
                w: 240.0,
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
                x: 100.0,
                y: 100.0,
                w: 140.0,
                h: 40.0,
                enabled: true,
                visible: true,
                props: vec![],
                children: vec![],
            },
            ControlDesc {
                id: 3,
                kind: "edit".into(),
                text: "seed".into(),
                x: 300.0,
                y: 100.0,
                w: 180.0,
                h: 32.0,
                enabled: true,
                visible: true,
                props: vec![("placeholder".into(), PropValue::Text("hint".into()))],
                children: vec![],
            },
        ],
    }
}

/// The pump is asynchronous: the UI thread services it on its own clock,
/// so tests wait on the events rather than the call returning.
fn wait_for(sink: &Sink, count: usize, prefix: &str) {
    for _ in 0..200 {
        if events_of(sink, prefix).len() >= count {
            return;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    panic!(
        "timed out waiting for {count} `{prefix}` events; have {:?}",
        events_of(sink, prefix)
    );
}

fn events_of(sink: &Sink, prefix: &str) -> Vec<String> {
    sink.0
        .lock()
        .unwrap()
        .iter()
        .filter(|(_, _, kind, _)| kind.starts_with(prefix))
        .map(|(_, _, kind, payload)| format!("{kind} {payload}"))
        .collect()
}

#[test]
fn loads_updates_clicks_reads_and_rejects() {
    let (session, sink) = spawn_ui();

    session
        .submit(Command {
            generation: 1,
            op: Op::LoadUi(form()),
        })
        .expect("LoadUi enqueues");
    testing::test_pump(32).expect("a pump is enqueued");
    wait_for(&sink, 1, "ui-loaded");

    // A property publish, then a read-back.
    session
        .submit(Command {
            generation: 1,
            op: Op::SetText {
                control: 1,
                value: "Count 41".into(),
            },
        })
        .expect("SetText enqueues");
    session
        .submit(Command {
            generation: 1,
            op: Op::ReadText {
                control: 1,
                key: "text".into(),
            },
        })
        .expect("ReadText enqueues");
    testing::test_pump(32).expect("a pump is enqueued");
    wait_for(&sink, 1, "read:1:text");
    let reads = events_of(&sink, "read:1:text");
    assert_eq!(
        reads,
        vec!["read:1:text Count 41".to_owned()],
        "the label round-trips"
    );

    // A click through the button's center (layout must have placed it).
    // Debug: where did the button land?
    testing::test_dump().expect("dump enqueued");
    for _ in 0..50 {
        if let Ok(replies) = testing::test_dump_replies() {
            if !replies.is_empty() {
                eprintln!("CAMPY dump: {:?}", replies.last());
                break;
            }
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    // One more pump so the button's layout frame is behind us: hit
    // testing uses the previous frame's fragments.
    testing::test_pump(32).expect("a pump is enqueued");
    std::thread::sleep(Duration::from_millis(50));
    testing::test_pointer("click", 170.0, 120.0).expect("the click is enqueued");
    testing::test_pump(32).expect("a pump is enqueued");
    wait_for(&sink, 1, "control:2:clicked");
    let clicks = events_of(&sink, "control:2:");
    assert_eq!(
        clicks,
        vec!["control:2:clicked ".to_owned()],
        "the button handler fired"
    );

    // Stale generations are rejected; the UI keeps running.
    session
        .submit(Command {
            generation: 0,
            op: Op::ReadText {
                control: 1,
                key: "text".into(),
            },
        })
        .expect("enqueue");
    testing::test_pump(32).expect("a pump is enqueued");
    wait_for(&sink, 1, "command-failed");
}
