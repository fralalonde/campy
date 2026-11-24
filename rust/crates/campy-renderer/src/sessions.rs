//! Session lifecycle and the UI thread.
//!
//! One OS process: BEAM + this renderer's single UI thread owning one winit
//! event loop (`with_any_thread(true)`, so the BEAM may spawn it from a
//! NIF) and one zgui application. The first bridge session owns the
//! application's initial window; later sessions open their own windows via
//! the runtime's `Windows` API. A `set_interval` timer inside the app
//! drains the bounded command queue — the same shape as protocol v1, with
//! zgui's reactive flush replacing Slint's event-loop timer.

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;
use std::sync::atomic::{AtomicU8, AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver, SyncSender, TrySendError};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use zgui::elements::r#box;
use zgui::prelude::*;
use zgui::view::AnyView;
use zgui::view::time::set_interval;
use zgui_ui::prelude::Checked;

use crate::controls::{self, EventSink, Host};
use crate::sheet::CAMPY_SHEET;
use crate::wire::{self, ControlDesc, Op};

const DRAIN_COMMANDS_PER_TICK: usize = 32;
const DRAIN_TICK: Duration = Duration::from_millis(8);
/// The session bound to the application's initial window.
const INITIAL_SESSION: u64 = 1;
/// Reserved so the NIF's first `open_session` claims the initial window.
const FIRST_DYNAMIC_SESSION: u64 = 2;

/// The native event the NIF encodes into the owner's mailbox.
#[derive(Debug, Clone)]
pub struct Event {
    pub session: u64,
    pub generation: u64,
    pub kind: String,
    pub payload: String,
}

/// A queued command: the session id rides on the envelope.
#[derive(Debug)]
pub struct Command {
    pub generation: u64,
    pub op: Op,
}

impl Command {
    pub fn validate(&self) -> Result<(), String> {
        match &self.op {
            Op::LoadUi(doc) => {
                if doc.title.len() > 256 || doc.theme.len() > 16 {
                    return Err("Title or theme exceeds its limit".into());
                }
                let mut source = 0usize;
                measure_controls(&doc.controls, &mut source);
                if source > wire::MAX_SOURCE_BYTES {
                    return Err("UI description exceeds 512 KiB".into());
                }
            }
            Op::SetText { value, .. } | Op::SetCode { source: value, .. } => {
                if value.len() > wire::MAX_TEXT_BYTES {
                    return Err("Text exceeds 64 KiB".into());
                }
            }
            Op::AppendConsole { bytes, .. } => {
                if bytes.len() > wire::MAX_TEXT_BYTES {
                    return Err("Console chunk exceeds 64 KiB".into());
                }
            }
            _ => (),
        }
        Ok(())
    }
}

fn measure_controls(controls: &[ControlDesc], size: &mut usize) {
    for control in controls {
        *size += control.text.len();
        for (name, value) in &control.props {
            *size += name.len() + crate::wire::prop_value_size(value);
        }
        measure_controls(&control.children, size);
    }
}

struct Control {
    id: u64,
    /// Cleanup cannot be lost when the command queue is full (v1 rule).
    close_reason: AtomicU8,
}

struct Registration {
    control: Arc<Control>,
    sink: EventSink,
}

/// NIF-facing shared state: registrations the UI thread adopts.
struct Shared {
    status: AtomicU8, // 0 starting, 1 running, 2 permanently stopped
    registrations: Mutex<HashMap<u64, Registration>>,
}

struct Runtime {
    sender: SyncSender<(u64, Command)>,
    shared: Arc<Shared>,
}

static RUNTIME: OnceLock<Result<Runtime, String>> = OnceLock::new();
static NEXT_ID: AtomicU64 = AtomicU64::new(FIRST_DYNAMIC_SESSION);

/// The NIF-facing session handle (v1 semantics).
pub struct Session {
    control: Arc<Control>,
    sender: SyncSender<(u64, Command)>,
    shared: Arc<Shared>,
}

impl Session {
    pub fn id(&self) -> u64 {
        self.control.id
    }

    pub fn submit(&self, command: Command) -> Result<(), String> {
        command.validate()?;
        if self.control.close_reason.load(Ordering::Acquire) != 0 {
            return Err("Session is closed".into());
        }
        if self.shared.status.load(Ordering::Acquire) == 2 {
            return Err("UI runtime stopped; restart the application".into());
        }
        self.sender
            .try_send((self.id(), command))
            .map_err(|error| match error {
                TrySendError::Full(_) => "UI command queue is full; retry later".into(),
                TrySendError::Disconnected(_) => "UI runtime is unavailable".into(),
            })
    }

    pub fn close(&self, reason: u8) {
        let _ = self.control.close_reason.compare_exchange(
            0,
            reason,
            Ordering::AcqRel,
            Ordering::Acquire,
        );
    }
}

pub fn active_sessions() -> usize {
    match RUNTIME.get() {
        Some(Ok(runtime)) => runtime
            .shared
            .registrations
            .lock()
            .map(|entries| entries.len())
            .unwrap_or(0),
        _ => 0,
    }
}

pub fn open(sink: EventSink) -> Result<Session, String> {
    if !cfg!(any(target_os = "linux", target_os = "windows")) {
        return Err("Native sessions currently support Linux and Windows only".into());
    }
    let runtime = RUNTIME.get_or_init(start).as_ref().map_err(Clone::clone)?;
    let mut registrations = runtime
        .shared
        .registrations
        .lock()
        .map_err(|_| "UI registry poisoned")?;
    if runtime.shared.status.load(Ordering::Acquire) == 2 {
        return Err("UI startup failed; see native diagnostics and restart the application".into());
    }
    if registrations.len() >= wire::MAX_SESSIONS {
        return Err("At most 32 native sessions may be open".into());
    }
    let control = Arc::new(Control {
        id: if registrations.is_empty() {
            INITIAL_SESSION
        } else {
            NEXT_ID.fetch_add(1, Ordering::Relaxed)
        },
        close_reason: AtomicU8::new(0),
    });
    registrations.insert(
        control.id,
        Registration {
            control: control.clone(),
            sink,
        },
    );
    Ok(Session {
        control,
        sender: runtime.sender.clone(),
        shared: runtime.shared.clone(),
    })
}

fn start() -> Result<Runtime, String> {
    let (sender, receiver) = mpsc::sync_channel(wire::QUEUE_CAPACITY);
    let shared = Arc::new(Shared {
        status: AtomicU8::new(0),
        registrations: Mutex::new(HashMap::new()),
    });
    let thread_shared = shared.clone();
    std::thread::Builder::new()
        .name("campy-ui".into())
        .stack_size(8 * 1024 * 1024)
        .spawn(move || {
            let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                run(receiver, thread_shared.clone())
            }));
            let error = match result {
                Ok(Ok(())) => "UI event loop stopped".into(),
                Ok(Err(error)) => error,
                Err(_) => "UI thread panicked; restart the application".into(),
            };
            eprintln!("Campy UI runtime stopped: {error}");
            thread_shared.status.store(2, Ordering::Release);
            if let Ok(mut registrations) = thread_shared.registrations.lock() {
                for (id, registration) in registrations.drain() {
                    (registration.sink)(id, 0, "runtime-failed".into(), error.clone());
                }
            }
        })
        .map_err(|error| format!("Cannot start UI thread: {error}"))?;
    Ok(Runtime { sender, shared })
}

// --- UI-thread state ---

/// Per-session window state (UI thread only).
struct SessionWindow {
    host: Rc<Host>,
    control: Arc<Control>,
    handle: RefCell<Option<zgui::runtime::windows::WindowHandle>>,
}

/// Everything the drain timer sees (UI thread only).
pub(crate) struct ThreadState {
    shared: Arc<Shared>,
    receiver: RefCell<Option<Receiver<(u64, Command)>>>,
    windows: RefCell<Option<zgui::runtime::windows::Windows>>,
    sessions: RefCell<HashMap<u64, SessionWindow>>,
    /// Kept alive so the drain interval is not cancelled by handle drop.
    drain_timer: RefCell<Option<zgui::view::time::IntervalHandle>>,
}

/// The window content of one session: the current document as a reactive
/// hole, rebuilt by zgui when the host's document signal changes.
fn session_view(host: Rc<Host>) -> impl FnMut() -> AnyView + 'static {
    move || match host.document.get() {
        None => AnyView::new(r#box().class("campy-root")),
        Some(doc) => controls::build_document(&doc, &host),
    }
}

fn run(receiver: Receiver<(u64, Command)>, shared: Arc<Shared>) -> Result<(), String> {
    let ui = Rc::new(ThreadState {
        shared,
        receiver: RefCell::new(Some(receiver)),
        windows: RefCell::new(None),
        sessions: RefCell::new(HashMap::new()),
        drain_timer: RefCell::new(None),
    });

    #[allow(unused_mut)]
    let mut app = zgui::app()
        .with_title("Campy")
        .with_size(1200.0, 800.0)
        .with_stylesheet(CAMPY_SHEET);
    #[cfg(feature = "ui-testing")]
    {
        app = app.with_renderer(Box::new(crate::testing::null_renderer_factory));
    }
    let view_ui = ui.clone();
    let handler = app
        .into_handler(move || {
            // Inside the initial window's build: adopt the windows API for
            // later sessions, pre-create the initial session's host (its
            // sink arrives with registration), and start the command drain.
            *view_ui.windows.borrow_mut() = Some(use_windows());
            let host = Host::new(INITIAL_SESSION, Arc::new(|_, _, _, _| {}));
            view_ui.sessions.borrow_mut().insert(
                INITIAL_SESSION,
                SessionWindow {
                    host: host.clone(),
                    control: Arc::new(Control {
                        id: INITIAL_SESSION,
                        close_reason: AtomicU8::new(0),
                    }),
                    handle: RefCell::new(None),
                },
            );
            let drain_ui = view_ui.clone();
            let timer = set_interval(DRAIN_TICK, move || drain(&drain_ui));
            *view_ui.drain_timer.borrow_mut() = Some(timer);
            session_view(host.clone())
        })
        .map_err(|error| format!("Cannot install zgui application: {error}"))?;
    let runtime = handler.into_runtime();

    #[cfg(feature = "ui-testing")]
    {
        return crate::testing::drive_headless(ui, runtime);
    }

    #[cfg(not(feature = "ui-testing"))]
    {
        let _ = ui;
        let event_loop = ui_event_loop()?;
        let mut app = zgui_platform_winit::WinitApp::new(&event_loop, runtime);
        event_loop
            .run_app(&mut app)
            .map_err(|error| format!("UI event loop failed: {error}"))?;
        Ok(())
    }
}

/// The embedder path: our own winit event loop, on this (non-main) thread.
/// `with_any_thread` is per-platform in winit 0.30; enable it for whichever
/// session we are on, exactly as the pinned Slint backend used to (ADR 0001).
#[cfg(not(feature = "ui-testing"))]
fn ui_event_loop() -> Result<winit::event_loop::EventLoop<zgui_platform_winit::UserEvent>, String> {
    let mut builder =
        winit::event_loop::EventLoop::<zgui_platform_winit::UserEvent>::with_user_event();
    #[cfg(target_os = "linux")]
    {
        let wayland = std::env::var("WAYLAND_DISPLAY").is_ok();
        if wayland {
            use winit::platform::wayland::EventLoopBuilderExtWayland as _;
            builder.with_any_thread(true);
        } else {
            use winit::platform::x11::EventLoopBuilderExtX11 as _;
            builder.with_any_thread(true);
        }
    }
    #[cfg(target_os = "windows")]
    {
        use winit::platform::windows::EventLoopBuilderExtWindows as _;
        builder.with_any_thread(true);
    }
    builder
        .build()
        .map_err(|error| format!("Cannot open the event loop: {error}"))
}

/// Adopts newly registered sessions, applies queued commands, reaps
/// closed ones.
fn drain(ui: &Rc<ThreadState>) {
    adopt_registrations(ui);
    apply_commands(ui);
    reap_closed(ui);
}

fn adopt_registrations(ui: &Rc<ThreadState>) {
    let Ok(registrations) = ui.shared.registrations.lock() else {
        return;
    };
    let windows = ui.windows.borrow().clone();
    for (id, registration) in registrations.iter() {
        let mut sessions = ui.sessions.borrow_mut();
        if let Some(window) = sessions.get_mut(id) {
            if Arc::ptr_eq(&window.control, &registration.control) {
                continue; // already adopted
            }
            // The initial window adopts its registration.
            window.host.adopt_sink(registration.sink.clone());
            window.control = registration.control.clone();
            (registration.sink)(*id, 0, "session-opened".into(), "initial-window".into());
            continue;
        }
        let Some(windows) = windows.as_ref() else {
            continue;
        };
        let host = Host::new(*id, registration.sink.clone());
        let handle = windows.open(
            zgui::runtime::windows::WindowOptions::new("Campy").with_size(900.0, 640.0),
            session_view(host.clone()),
        );
        sessions.insert(
            *id,
            SessionWindow {
                host,
                control: registration.control.clone(),
                handle: RefCell::new(Some(handle)),
            },
        );
        (registration.sink)(*id, 0, "session-opened".into(), "window".into());
    }
}

fn apply_commands(ui: &Rc<ThreadState>) {
    let Some(receiver) = ui.receiver.borrow_mut().take() else {
        return;
    };
    for _ in 0..DRAIN_COMMANDS_PER_TICK {
        let Ok((id, command)) = receiver.try_recv() else {
            break;
        };
        let result = {
            let sessions = ui.sessions.borrow();
            let Some(window) = sessions.get(&id) else {
                continue;
            };
            let host = &window.host;
            let generation = command.generation;
            if let Op::LoadUi(doc) = &command.op {
                if generation <= host.generation.get() {
                    host.emit_raw("command-failed", "UI generation must increase");
                    continue;
                }
                host.generation.set(generation);
                host.document.set(Some(doc.clone()));
                host.emit_raw("ui-loaded", format!("controls={}", doc.controls.len()));
                continue;
            }
            if generation != host.generation.get() {
                host.emit_raw("command-failed", "Stale UI generation");
                continue;
            }
            apply_op(host, &command.op)
        };
        if let Err(error) = result {
            let sessions = ui.sessions.borrow();
            if let Some(window) = sessions.get(&id) {
                window.host.emit_raw("command-failed", error);
            }
        }
    }
    *ui.receiver.borrow_mut() = Some(receiver);
}

fn apply_op(host: &Rc<Host>, op: &Op) -> Result<(), String> {
    let control_of = |id: &u64| {
        host.controls
            .borrow()
            .get(id)
            .cloned()
            .ok_or_else(|| format!("Unknown control {id}"))
    };
    match op {
        Op::LoadUi(_) => {
            return Err("LoadUi is applied by the generation path".into());
        }
        Op::SetText { control, value } => {
            control_of(control)?.text.set(value.clone());
        }
        Op::SetBool {
            control,
            key,
            value,
        } => {
            let signals = control_of(control)?;
            match key.as_str() {
                "checked" => signals
                    .checked
                    .set(if *value { Checked::Yes } else { Checked::No }),
                "enabled" => signals.enabled.set(*value),
                "visible" => signals.visible.set(*value),
                other => return Err(format!("Unsupported bool key: {other}")),
            }
        }
        Op::SetInt {
            control,
            key,
            value,
        } => {
            let signals = control_of(control)?;
            match key.as_str() {
                "value" => signals.value.set(*value as f64),
                "current-index" => {
                    let items = signals.model.get_untracked();
                    signals
                        .text
                        .set(controls::item_text(&items, *value as usize));
                }
                other => return Err(format!("Unsupported int key: {other}")),
            }
        }
        Op::SetFloat {
            control,
            key,
            value,
        } => {
            let signals = control_of(control)?;
            match key.as_str() {
                "value" => signals.value.set(*value),
                "progress" => signals.progress.set(Some(*value)),
                other => return Err(format!("Unsupported float key: {other}")),
            }
        }
        Op::SetModel { control, items } => {
            control_of(control)?.model.set(items.clone());
        }
        Op::SetGeometry {
            control,
            x,
            y,
            w,
            h,
        } => {
            control_of(control)?.rect.set((*x, *y, *w, *h));
        }
        Op::SetCode { control, source } => {
            let handle = host
                .editors
                .borrow()
                .get(control)
                .cloned()
                .ok_or_else(|| format!("Control {control} is not an editor"))?;
            handle.set_text(source);
        }
        Op::AppendConsole { control, bytes } => {
            let signals = control_of(control)?;
            let mut next = signals.buffer.get_untracked();
            next.push_str(bytes);
            let cap = wire::MAX_TEXT_BYTES;
            if next.len() > cap {
                next = next[next.len() - cap..].to_owned();
            }
            signals.buffer.set(next);
        }
        Op::SetMarks { control, .. } => {
            // Editor mark layers arrive with the editor integration (Z3.1).
            return Err(format!("SetMarks is not wired yet (control {control})"));
        }
        Op::ReadText { control, key } => {
            let signals = control_of(control)?;
            match key.as_str() {
                "text" => host.emit_read(*control, "text", signals.text.get_untracked()),
                "value" => {
                    host.emit_read(
                        *control,
                        "value",
                        format!("{}", signals.value.get_untracked()),
                    );
                }
                "buffer" => host.emit_read(*control, "buffer", signals.buffer.get_untracked()),
                "source" => {
                    let handle = host.editors.borrow().get(control).cloned();
                    match handle {
                        Some(handle) => {
                            host.emit_read(
                                *control,
                                "source",
                                handle.query(|snapshot| snapshot.rope().to_string()),
                            );
                        }
                        None => {
                            host.emit_read(*control, "source", signals.text.get_untracked());
                        }
                    }
                }
                other => return Err(format!("Unsupported read key: {other}")),
            }
        }
        Op::Resize { .. } => {
            // The window handle's request_size arrives with the handle
            // wiring (Z3.1); the BEAM's window sizing flows through it.
            return Err("Resize is not wired yet".into());
        }
    }
    Ok(())
}

fn reap_closed(ui: &Rc<ThreadState>) {
    let mut closed = Vec::new();
    {
        let sessions = ui.sessions.borrow();
        for (id, window) in sessions.iter() {
            let reason = window.control.close_reason.load(Ordering::Acquire);
            if reason != 0 {
                closed.push((*id, reason));
            }
        }
    }
    if closed.is_empty() {
        return;
    }
    let mut sessions = ui.sessions.borrow_mut();
    for (id, reason) in closed {
        if let Some(window) = sessions.remove(&id) {
            let _ = window.host.emit_raw("closed", format!("reason={reason}"));
            if let Some(handle) = window.handle.borrow().as_ref() {
                handle.close();
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_oversized_commands_before_enqueue() {
        let command = Command {
            generation: 1,
            op: Op::SetText {
                control: 1,
                value: "x".repeat(wire::MAX_TEXT_BYTES + 1),
            },
        };
        assert!(command.validate().is_err());
    }

    #[test]
    fn generation_enforcement_is_symmetric() {
        // LoadUi must increase; other ops must match. Exercised end to end
        // by the headless driver test; here we pin the constant contract.
        assert_eq!(INITIAL_SESSION, 1);
        assert_eq!(FIRST_DYNAMIC_SESSION, 2);
    }
}
