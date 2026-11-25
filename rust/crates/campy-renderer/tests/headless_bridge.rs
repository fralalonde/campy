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
                props: vec![("hint".into(), PropValue::Text("Click me — a hint".into()))],
                children: vec![],
            },
            ControlDesc {
                id: 4,
                kind: "menu".into(),
                text: "File".into(),
                x: 400.0,
                y: 16.0,
                w: 90.0,
                h: 32.0,
                enabled: true,
                visible: true,
                props: vec![(
                    "model".into(),
                    PropValue::List(vec![
                        PropValue::Text("Save    Ctrl+S".into()),
                        PropValue::Text("—".into()),
                        PropValue::Text("Quit    Ctrl+Q".into()),
                    ]),
                )],
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
    // Pump while waiting: the drain only runs on virtual-clock ticks, and
    // multi-step sequences (deferred window builds, swaps) need several.
    for _ in 0..200 {
        let _ = testing::test_pump(16);
        if events_of(sink, prefix).len() >= count {
            return;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    panic!(
        "timed out waiting for {count} `{prefix}` events; all events: {:?}",
        sink.0.lock().unwrap()
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
    let first_sink = sink.clone();

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
    // The pointer entered a control that carries a hint, so the loop was told:
    // this is the hover half of the old shell's tooltips.
    let hovers = events_of(&sink, "hover");
    assert!(
        hovers.contains(&"hover Click me — a hint".to_owned()),
        "expected a hover hint, got {hovers:?}"
    );
    let clicks = events_of(&sink, "control:2:");
    assert_eq!(
        clicks,
        vec!["control:2:clicked ".to_owned()],
        "the button handler fired"
    );

    // A menu opens its model as a popup and emits the chosen label: the loop
    // routes `selected` by the old item titles, shortcuts included.
    testing::test_pointer("click", 445.0, 32.0).expect("the menu trigger is clicked");
    testing::test_pump(32).expect("a pump is enqueued");
    std::thread::sleep(Duration::from_millis(80));
    // The popup sits under the trigger: 4px of padding, then 26px rows, so the
    // first item's middle is 17px below the popup's top edge.
    testing::test_pointer("click", 500.0, 67.0).expect("the first item is clicked");
    testing::test_pump(32).expect("a pump is enqueued");
    wait_for(&sink, 1, "control:4:selected");
    assert_eq!(
        events_of(&sink, "control:4:"),
        vec!["control:4:selected Save    Ctrl+S".to_owned()],
        "the menu emitted the item's label"
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
    // --- Second session: the deferred-window path (the IDE's preview) --
    // A second registration opens its own window through the runtime's
    // deferred `windows.open` flow. Loads swap that window (the reactive
    // rebuild does not fire there), and commands stall until its first
    // build. One runtime per process: this runs in the same test.
    let preview_sink = Sink::default();
    let events = preview_sink.0.clone();
    let handle = Arc::new(
        move |session: u64, generation: u64, kind: String, payload: String| {
            events
                .lock()
                .unwrap()
                .push((session, generation, kind, payload));
        },
    );
    let preview = sessions::open(handle).expect("a second session opens");
    preview
        .submit(Command {
            generation: 1,
            op: Op::LoadUi(form()),
        })
        .expect("the preview loads");
    wait_for(&preview_sink, 1, "ui-loaded");

    // The reload adds a control; the swap must make it addressable.
    let mut reloaded = form();
    reloaded.controls.push(ControlDesc {
        id: 7,
        kind: "label".into(),
        text: "Rebuilt".into(),
        x: 600.0,
        y: 16.0,
        w: 180.0,
        h: 24.0,
        enabled: true,
        visible: true,
        props: vec![],
        children: vec![],
    });
    preview
        .submit(Command {
            generation: 2,
            op: Op::LoadUi(reloaded),
        })
        .expect("the preview reloads");
    wait_for(&preview_sink, 2, "ui-loaded");
    preview
        .submit(Command {
            generation: 2,
            op: Op::ReadText {
                control: 7,
                key: "text".into(),
            },
        })
        .expect("ReadText enqueues");
    wait_for(&preview_sink, 1, "read:7:text");
    let rebuilt = events_of(&preview_sink, "read:7:text");
    assert_eq!(
        rebuilt,
        vec!["read:7:text Rebuilt".to_owned()],
        "the swapped window rendered the new control"
    );

    // The swap closed the *old* window itself. That must not read as the
    // session closing: it still owns the new window, and treating it as closed
    // made the UI thread re-open a window for the still-registered session on
    // every drain tick — a Cat Café window per 8ms until the desktop died.
    let closed_by_swap = events_of(&preview_sink, "closed");
    assert!(
        closed_by_swap.is_empty(),
        "a window swap reported the session as closed: {closed_by_swap:?}"
    );

    // Both sessions stay healthy; closing the preview reaps only it.
    assert_eq!(sessions::active_sessions(), 2);
    preview.close(1);
    wait_for(&preview_sink, 1, "closed");
    let _ = first_sink;

    // A window the user closes is a *reaped* session, not a forgotten one. The
    // NIF still holds its registration until the BEAM closes it, so a UI thread
    // that adopts it again opens a window that is immediately closed again —
    // one Cat Café window per drain tick, each one taking focus. Adoption must
    // happen once per registration, not once per tick.
    let reaped_sink = Sink::default();
    let events = reaped_sink.0.clone();
    let handle = Arc::new(
        move |session: u64, generation: u64, kind: String, payload: String| {
            events
                .lock()
                .unwrap()
                .push((session, generation, kind, payload));
        },
    );
    let user_closed = sessions::open(handle).expect("a third session opens");
    user_closed
        .submit(Command {
            generation: 1,
            op: Op::LoadUi(form()),
        })
        .expect("the third session loads");
    wait_for(&reaped_sink, 1, "ui-loaded");
    // Reason 4 is the window's own close button.
    user_closed.close(4);
    wait_for(&reaped_sink, 1, "closed");
    // Give the drain many ticks to re-adopt it if it were going to.
    for _ in 0..12 {
        let _ = testing::test_pump(32);
        std::thread::sleep(Duration::from_millis(15));
    }
    let adopted = events_of(&reaped_sink, "session-opened");
    assert_eq!(
        adopted.len(),
        1,
        "a reaped session was adopted again: {adopted:?}"
    );
    let closed_once = events_of(&reaped_sink, "closed");
    assert_eq!(
        closed_once.len(),
        1,
        "a reaped session closed more than once: {closed_once:?}"
    );
}
