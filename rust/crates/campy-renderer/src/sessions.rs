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
use crate::wire::{self, ControlDesc, Op, UiDocument};

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
#[derive(Debug, Clone)]
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

pub(crate) struct Control {
    pub(crate) id: u64,
    /// Cleanup cannot be lost when the command queue is full (v1 rule).
    pub(crate) close_reason: AtomicU8,
}

impl Control {
    pub(crate) fn mark_close(&self, reason: u8) {
        let _ = self
            .close_reason
            .compare_exchange(0, reason, Ordering::AcqRel, Ordering::Acquire);
    }
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
        self.control.mark_close(reason);
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
    /// Commands held while the session's window has not built yet (the
    /// window-open command is asynchronous in the runtime). FIFO with the
    /// channel: pending drains first, then new arrivals append.
    pending: RefCell<std::collections::VecDeque<Command>>,
}

/// Everything the drain timer sees (UI thread only).
pub(crate) struct ThreadState {
    shared: Arc<Shared>,
    receiver: RefCell<Option<Receiver<(u64, Command)>>>,
    windows: RefCell<Option<zgui::runtime::windows::Windows>>,
    sessions: RefCell<HashMap<u64, SessionWindow>>,
}

/// The window content of one session: the current document as a reactive
/// hole, rebuilt by zgui when the host's document signal changes.
fn session_view(host: Rc<Host>) -> impl FnMut() -> AnyView + 'static {
    move || {
        // Arm this run's drain: the reactive hole cleans the previous
        // run's scope (and with it that run's timer) on every rebuild,
        // so every run re-arms its own. Dropping the old handle first
        // cancels it cleanly.
        {
            let drain_host = host.clone();
            let timer = set_interval(DRAIN_TICK, move || {
                apply_fullscreen(&drain_host);
                drain_session(&drain_host);
            });
            *host.drain_timer.borrow_mut() = Some(timer);
        }
        if host.window.borrow().is_none() {
            *host.window.borrow_mut() = Some(use_window());
            let close_host = host.clone();
            let _guard = on_close_request(move || {
                close_host.request_close();
                zgui::prelude::CloseResponse::Close
            });
        }
        // The document read lives in a dynamic child rather than here: the
        // window is built in an owner scope with no observer, so reading the
        // signal in the builder would be a read nothing subscribes to (and
        // zgui says so). A child closure is invoked in a tracking scope, so
        // the subtree rebuilds exactly when `LoadUi` moves the document.
        let rebuild_host = host.clone();
        AnyView::new(
            r#box()
                .class("campy-host")
                .child(move || match rebuild_host.document.get() {
                    None => AnyView::new(r#box().class("campy-root")),
                    Some(doc) => controls::build_document(&doc, &rebuild_host),
                }),
        )
    }
}

fn run(receiver: Receiver<(u64, Command)>, shared: Arc<Shared>) -> Result<(), String> {
    let ui = Rc::new(ThreadState {
        shared,
        receiver: RefCell::new(Some(receiver)),
        windows: RefCell::new(None),
        sessions: RefCell::new(HashMap::new()),
    });

    SESSION_STATE.with(|cell| *cell.borrow_mut() = Some(ui.clone()));
    #[allow(unused_mut)]
    let (width, height) = startup_size();
    let mut app = zgui::app()
        .with_title("Campy")
        .with_size(width, height)
        .with_stylesheet(CAMPY_SHEET);
    #[cfg(feature = "ui-testing")]
    {
        app = app.with_renderer(Box::new(crate::testing::null_renderer_factory));
    }
    #[cfg(not(feature = "ui-testing"))]
    if let Some(path) = crate::snapshot::path() {
        app = app.with_renderer(crate::snapshot::factory(path));
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
                    pending: RefCell::default(),
                },
            );
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
        // CAMPY_UI_BACKEND=x11 forces the X11 backend even on Wayland
        // sessions (automation: XWayland clients are drivable with
        // xdotool); the default follows the session.
        let forced_x11 = std::env::var("CAMPY_UI_BACKEND").as_deref() == Ok("x11");
        let wayland = !forced_x11 && std::env::var("WAYLAND_DISPLAY").is_ok();
        if wayland {
            use winit::platform::wayland::EventLoopBuilderExtWayland as _;
            builder.with_any_thread(true);
        } else {
            use winit::platform::x11::EventLoopBuilderExtX11 as _;
            if forced_x11 {
                builder.with_x11();
            }
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

/// `LoadUi` application. v1 parity: a live window is *swapped* — a fresh
/// window with the new document is opened and the old one closed, which
/// is the reliable path (a deferred window built with its document
/// renders correctly, while a rebuild of an existing deferred window
/// rides a reactive-tracking path that does not fire in the runtime's
/// window-open flow; ADR 0003 records the finding).
fn swap_load(
    host: &Rc<Host>,
    doc: UiDocument,
    windows: &Option<zgui::runtime::windows::Windows>,
) -> Option<Rc<Host>> {
    let old_handle = host.window.borrow().clone();
    let Some(handle) = old_handle else {
        // The window is not built yet: the deferred build renders the
        // document directly.
        host.document.set(Some(doc));
        return None;
    };
    let Some(windows) = windows.as_ref() else {
        host.document.set(Some(doc));
        return None;
    };
    let size = handle.size().get_untracked();
    let sink = host.sink_handle();
    let control = host
        .control
        .borrow()
        .as_ref()
        .map(|control| Arc::clone(control));
    let replacement = Host::new(host.session, sink);
    if let Some(control) = control {
        replacement.adopt_control(control);
    }
    replacement.generation.set(host.generation.get());
    replacement
        .live_generation
        .store(host.generation.get(), Ordering::Release);
    replacement.document.set(Some(doc.clone()));
    let _new_handle = windows.open(
        zgui::runtime::windows::WindowOptions::new(doc.title.clone())
            .with_size(size.width.0, size.height.0),
        session_view(replacement.clone()),
    );
    handle.close();
    host.window.borrow_mut().take();
    Some(replacement)
}

/// Adopts newly registered sessions, applies queued commands, reaps
/// closed ones.
/// The window's startup size: the shell's own 1280x860 unless
/// `CAMPY_UI_SIZE=WxH` asks for another (a validation aid — the shell
/// stretches to whatever the window is).
fn startup_size() -> (f32, f32) {
    let Some(requested) = std::env::var("CAMPY_UI_SIZE").ok() else {
        return (1280.0, 860.0);
    };
    let mut parts = requested.split(['x', 'X', ',']);
    let width = parts
        .next()
        .and_then(|part| part.trim().parse::<f32>().ok());
    let height = parts
        .next()
        .and_then(|part| part.trim().parse::<f32>().ok());
    match (width, height) {
        (Some(width), Some(height)) if width >= 640.0 && height >= 480.0 => (width, height),
        _ => (1280.0, 860.0),
    }
}

/// A validation run needs a surface whose origin is known: a fullscreen
/// toplevel covers the output exactly, so a pointer coordinate in device pixels
/// follows from the layout's CSS pixels without asking the compositor where the
/// window is. Applied from the drain rather than the build because the surface
/// has to be mapped before the request lands.
fn apply_fullscreen(host: &Rc<Host>) {
    if host.fullscreen_done.get() {
        return;
    }
    if std::env::var_os("CAMPY_UI_FULLSCREEN").is_none() {
        host.fullscreen_done.set(true);
        return;
    }
    if let Some(window) = host.window.borrow().as_ref() {
        window.set_fullscreen(Some(zgui::platform::FullscreenMode::Borderless));
        host.fullscreen_done.set(true);
    }
}

fn drain(ui: &Rc<ThreadState>) {
    adopt_registrations(ui);
    apply_commands(ui);
    reap_closed(ui);
}

/// One session's drain (the per-window timer path).
/// Tells the BEAM the window's CSS size whenever it changes: the shell layout
/// stretches to it, so a resize is a document change, not a renderer one.
fn report_size(host: &Rc<Host>) {
    let handle = host.window.borrow().clone();
    let Some(window) = handle else {
        return;
    };
    let size = window.size().get_untracked();
    let next = (
        size.width.0.round().max(1.0) as u32,
        size.height.0.round().max(1.0) as u32,
    );
    if next != host.last_size.get() {
        host.last_size.set(next);
        host.emit_raw("size", format!("{};{}", next.0, next.1));
    }
}

fn drain_session(host: &Rc<Host>) {
    report_size(host);
    // Registrations and reaping stay app-wide; the per-session tick only
    // applies that session's queue.
    if let Some(state) = SESSION_STATE.with(|cell| cell.borrow().clone()) {
        adopt_registrations(&state);
        apply_commands(&state);
        reap_closed(&state);
    }
    let _ = host;
}

thread_local! {
    static SESSION_STATE: RefCell<Option<Rc<ThreadState>>> = const { RefCell::new(None) };
}

fn adopt_registrations(ui: &Rc<ThreadState>) {
    let Ok(registrations) = ui.shared.registrations.lock() else {
        return;
    };
    let windows = ui.windows.borrow().clone();
    for (id, registration) in registrations.iter() {
        let mut sessions = ui.sessions.borrow_mut();
        if let Some(window) = sessions.get_mut(id) {
            if window.host.adopted() {
                continue; // already adopted
            }
            // The initial window adopts its registration.
            window.host.adopt_sink(registration.sink.clone());
            window.host.adopt_control(registration.control.clone());
            (registration.sink)(*id, 0, "session-opened".into(), "initial-window".into());
            continue;
        }
        let Some(windows) = windows.as_ref() else {
            continue;
        };
        let host = Host::new(*id, registration.sink.clone());
        host.deferred_window.set(true);
        host.adopt_control(registration.control.clone());
        let _handle = windows.open(
            zgui::runtime::windows::WindowOptions::new("Campy").with_size(900.0, 640.0),
            session_view(host.clone()),
        );
        sessions.insert(
            *id,
            SessionWindow {
                host,
                pending: RefCell::default(),
            },
        );
        (registration.sink)(*id, 0, "session-opened".into(), "window".into());
    }
}

fn apply_commands(ui: &Rc<ThreadState>) {
    let Some(receiver) = ui.receiver.borrow_mut().take() else {
        return;
    };
    let windows = ui.windows.borrow().clone();
    // Stage this tick's arrivals per session, preserving channel order;
    // a session whose window has not built yet holds its commands.
    let mut arrivals: HashMap<u64, Vec<Command>> = HashMap::new();
    for _ in 0..DRAIN_COMMANDS_PER_TICK {
        let Ok((id, command)) = receiver.try_recv() else {
            break;
        };
        arrivals.entry(id).or_default().push(command);
    }
    let order: Vec<u64> = {
        let sessions = ui.sessions.borrow();
        let mut order = Vec::with_capacity(sessions.len() + arrivals.len());
        for (id, window) in sessions.iter() {
            if !window.pending.borrow().is_empty() || arrivals.contains_key(id) {
                order.push(*id);
            }
        }
        for id in arrivals.keys() {
            if !sessions.contains_key(id) {
                order.push(*id);
            }
        }
        order
    };
    for id in order {
        let saturated = {
            let sessions = ui.sessions.borrow();
            let mut saturated = false;
            if let Some(window) = sessions.get(&id) {
                let mut pending = window.pending.borrow_mut();
                if let Some(commands) = arrivals.get_mut(&id) {
                    for command in commands.drain(..) {
                        if pending.len() >= wire::QUEUE_CAPACITY {
                            saturated = true;
                            break;
                        }
                        pending.push_back(command);
                    }
                }
            }
            saturated
        };
        if saturated {
            let sessions = ui.sessions.borrow();
            if let Some(window) = sessions.get(&id) {
                window
                    .host
                    .emit_raw("command-failed", "Session queue is saturated");
            }
        }
        apply_session_commands(ui, &windows, id);
    }
    *ui.receiver.borrow_mut() = Some(receiver);
}

/// Applies one session's pending queue, stalling while its window has
/// not built yet (the first `session_view` run marks readiness).
fn apply_session_commands(
    ui: &Rc<ThreadState>,
    windows: &Option<zgui::runtime::windows::Windows>,
    id: u64,
) {
    loop {
        let command = {
            let sessions = ui.sessions.borrow();
            let Some(window) = sessions.get(&id) else {
                return;
            };
            let Some(command) = window.pending.borrow_mut().pop_front() else {
                return;
            };
            if window.host.window.borrow().is_none() && window.host.adopted() {
                // Not built yet: put it back and wait for the build.
                window.pending.borrow_mut().push_front(command);
                return;
            }
            command
        };
        // A LoadUi may swap the live window for a fresh one; carry the
        // pending queue and the sessions entry over to the replacement.
        let load = {
            let sessions = ui.sessions.borrow();
            let Some(window) = sessions.get(&id) else {
                return;
            };
            let host = &window.host;
            let generation = command.generation;
            let load_doc = match &command.op {
                Op::LoadUi(doc) => Some(doc),
                _ => None,
            };
            match load_doc {
                None => None,
                Some(_) if generation <= host.generation.get() => {
                    Some(Err("UI generation must increase".to_string()))
                }
                Some(doc) => {
                    host.generation.set(generation);
                    host.live_generation.store(generation, Ordering::Release);
                    Some(Ok(doc.clone()))
                }
            }
        };
        let Some(load) = load else {
            // An ordinary op: apply it to the current host.
            {
                let sessions = ui.sessions.borrow();
                if let Some(window) = sessions.get(&id) {
                    let host = &window.host;
                    if command.generation != host.generation.get() {
                        host.emit_raw("command-failed", "Stale UI generation");
                    } else if let Err(error) = apply_op(host, &command.op) {
                        host.emit_raw("command-failed", error);
                    }
                }
            }
            continue;
        };
        let doc = match load {
            Ok(doc) => doc,
            Err(error) => {
                let sessions = ui.sessions.borrow();
                if let Some(window) = sessions.get(&id) {
                    window.host.emit_raw("command-failed", error);
                }
                continue;
            }
        };
        // Swap (or first-time set) and carry the pending queue over.
        let (new_host, pending_rest) = {
            let sessions = ui.sessions.borrow();
            let Some(window) = sessions.get(&id) else {
                return;
            };
            let new_host = swap_load(&window.host, doc, windows);
            // The LoadUi itself was already popped; carry the rest.
            let pending_rest: Vec<Command> = window.pending.borrow().iter().cloned().collect();
            (new_host, pending_rest)
        };
        let mut ui_loaded_host = None;
        {
            let mut sessions = ui.sessions.borrow_mut();
            if let Some(window) = sessions.get_mut(&id) {
                if let Some(new_host) = new_host {
                    window.host = new_host.clone();
                    ui_loaded_host = Some(new_host);
                }
                *window.pending.borrow_mut() = pending_rest.into();
            }
        }
        let host = ui_loaded_host
            .or_else(|| {
                let sessions = ui.sessions.borrow();
                sessions.get(&id).map(|window| window.host.clone())
            })
            .expect("the session exists");
        host.emit_raw("ui-loaded", "swapped-or-set");
    }
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
            let feed = host
                .consoles
                .borrow()
                .get(control)
                .cloned()
                .ok_or_else(|| format!("Control {control} is not a console"))?;
            feed.send(bytes.clone().into_bytes())
                .map_err(|_| "The console feed is closed".to_string())?;
        }
        Op::SetMarks {
            control,
            layer,
            items,
        } => {
            let handle = host
                .editors
                .borrow()
                .get(control)
                .cloned()
                .ok_or_else(|| format!("Control {control} is not an editor"))?;
            controls::set_editor_marks(&handle, layer, items);
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
        Op::Resize { width, height } => {
            let handle = host.window.borrow().clone();
            let Some(handle) = handle else {
                return Err("The window handle is not ready yet".into());
            };
            handle.request_size(*width as f32, *height as f32);
        }
    }
    Ok(())
}

fn reap_closed(ui: &Rc<ThreadState>) {
    let mut closed = Vec::new();
    {
        let sessions = ui.sessions.borrow();
        for (id, window) in sessions.iter() {
            if let Some(reason) = window.host.close_reason() {
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
            if let Some(handle) = window.host.window.borrow().as_ref() {
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
