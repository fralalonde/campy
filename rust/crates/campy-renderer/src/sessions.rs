//! Winit adapter. Live Slint values never leave this dedicated UI thread.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU8, AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver, SyncSender};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use slint::{ComponentHandle, ModelRc, Timer, TimerMode, VecModel};
use slint_interpreter::{ComponentInstance, Struct, Value};

const QUEUE_CAPACITY: usize = 4096;
const MAX_SESSIONS: usize = 32;
const MAX_SOURCE_BYTES: usize = 256 * 1024;
const MAX_TEXT_BYTES: usize = 64 * 1024;

#[derive(Debug)]
pub enum Command {
    LoadUi(u64, String),
    SetText(u64, String, String),
    SetBool(u64, String, bool),
    SetInt(u64, String, i64),
    SetModel(u64, String, Vec<PropValue>),
    SetColor(u64, String, String),
    ReadText(u64, String),
    Resize(u64, u32, u32),
    Snapshot(u64, String),
    #[cfg(feature = "ui-testing")]
    TestInput(u64, TestInput),
}

#[cfg(feature = "ui-testing")]
#[derive(Debug)]
pub enum TestInput {
    Click(f32, f32),
    Text(String),
    KeyCombo(Vec<String>),
    Close,
}

// A wire-friendly property value used by SetModel. Struct/list values let the
// host drive `for` loops over Slint models without regenerating the UI source.
#[derive(Debug)]
pub enum PropValue {
    Text(String),
    Bool(bool),
    Int(i64),
    List(Vec<PropValue>),
    Struct(Vec<(String, PropValue)>),
    Image(String),
}

impl Command {
    fn generation(&self) -> u64 {
        match self {
            Self::LoadUi(g, _)
            | Self::SetText(g, _, _)
            | Self::SetBool(g, _, _)
            | Self::SetInt(g, _, _)
            | Self::SetModel(g, _, _)
            | Self::SetColor(g, _, _)
            | Self::ReadText(g, _)
            | Self::Resize(g, _, _)
            | Self::Snapshot(g, _) => *g,
            #[cfg(feature = "ui-testing")]
            Self::TestInput(g, _) => *g,
        }
    }

    fn validate(&self) -> Result<(), String> {
        if self.generation() == 0 {
            return Err("Generation must be positive".into());
        }
        match self {
            Self::LoadUi(_, text) if text.len() > MAX_SOURCE_BYTES => {
                Err("UI source exceeds 256 KiB".into())
            }
            Self::SetText(_, name, text) if name.len() > 256 || text.len() > MAX_TEXT_BYTES => {
                Err("Property name or text exceeds its limit".into())
            }
            Self::SetInt(_, name, _) if name.len() > 256 => Err("Property name is too long".into()),
            Self::SetModel(_, name, _) if name.len() > 256 => {
                Err("Property name is too long".into())
            }
            Self::SetColor(_, name, _) if name.len() > 256 => {
                Err("Property name is too long".into())
            }
            Self::Resize(_, w, h) if *w == 0 || *h == 0 || *w > 8192 || *h > 8192 => {
                Err("Window dimensions must be between 1 and 8192 pixels".into())
            }
            Self::Snapshot(_, path) if path.len() > 4096 => Err("Snapshot path is too long".into()),
            _ => Ok(()),
        }
    }
}

pub struct Event {
    pub session: u64,
    pub generation: u64,
    pub kind: String,
    pub payload: String,
}

// Callback arguments cross the bridge as strings. Integral numbers are
// rendered without a trailing ".0" so Gleam can parse them as Ints.
fn number_text(value: f64) -> String {
    if value.is_finite() && value.fract() == 0.0 && value.abs() <= 1e15 {
        format!("{}", value as i64)
    } else {
        value.to_string()
    }
}

fn prop_value(value: PropValue) -> Result<Value, String> {
    Ok(match value {
        PropValue::Text(text) => Value::String(text.into()),
        PropValue::Bool(value) => Value::Bool(value),
        PropValue::Int(value) => Value::Number(value as f64),
        PropValue::List(items) => {
            let values: Vec<Value> = items
                .into_iter()
                .map(prop_value)
                .collect::<Result<_, String>>()?;
            Value::Model(ModelRc::new(VecModel::from(values)))
        }
        PropValue::Struct(fields) => {
            let mut object = Struct::default();
            for (name, value) in fields {
                object.set_field(name, prop_value(value)?);
            }
            Value::Struct(object)
        }
        PropValue::Image(path) => Value::Image(if path.is_empty() {
            slint::Image::default()
        } else {
            slint::Image::load_from_path(std::path::Path::new(&path)).unwrap_or_default()
        }),
    })
}

fn parse_hex(hex: &str) -> Result<slint::Color, String> {
    let hex = hex.strip_prefix('#').unwrap_or(hex);
    if hex.len() != 6 {
        return Err("Colors must be #rrggbb".into());
    }
    let read = |range: std::ops::Range<usize>| {
        u8::from_str_radix(&hex[range], 16).map_err(|_| "Invalid color".to_string())
    };
    Ok(slint::Color::from_rgb_f32(
        read(0..2)? as f32 / 255.0,
        read(2..4)? as f32 / 255.0,
        read(4..6)? as f32 / 255.0,
    ))
}

pub type EventSink = Arc<dyn Fn(Event) + Send + Sync>;

struct Control {
    id: u64,
    // Cleanup cannot be lost when the command queue is full.
    close_reason: AtomicU8,
}

struct Registration {
    control: Arc<Control>,
    sink: EventSink,
}

struct Shared {
    status: AtomicU8, // 0 starting, 1 running, 2 permanently stopped
    registrations: Mutex<HashMap<u64, Registration>>,
}

struct Runtime {
    sender: SyncSender<(u64, Command)>,
    shared: Arc<Shared>,
}

static RUNTIME: OnceLock<Result<Runtime, String>> = OnceLock::new();
static NEXT_ID: AtomicU64 = AtomicU64::new(1);

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
                mpsc::TrySendError::Full(_) => "UI command queue is full; retry later".into(),
                mpsc::TrySendError::Disconnected(_) => "UI runtime is unavailable".into(),
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
        return Err("Native sessions currently support Linux and Windows Winit only".into());
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
    if registrations.len() >= MAX_SESSIONS {
        return Err("At most 32 native sessions may be open".into());
    }
    let control = Arc::new(Control {
        id: NEXT_ID.fetch_add(1, Ordering::Relaxed),
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
    let (sender, receiver) = mpsc::sync_channel(QUEUE_CAPACITY);
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
            {
                let mut registrations = thread_shared
                    .registrations
                    .lock()
                    .unwrap_or_else(|poison| poison.into_inner());
                for (id, registration) in registrations.drain() {
                    (registration.sink)(Event {
                        session: id,
                        generation: 0,
                        kind: "runtime-failed".into(),
                        payload: error.clone(),
                    });
                }
            }
        })
        .map_err(|error| format!("Cannot start UI thread: {error}"))?;
    Ok(Runtime { sender, shared })
}

struct LiveSession {
    control: Arc<Control>,
    sink: EventSink,
    instance: Option<ComponentInstance>,
    generation: u64,
}

fn thread_detail() -> String {
    #[cfg(target_os = "linux")]
    let tid = std::fs::read_link("/proc/thread-self")
        .ok()
        .and_then(|path| {
            path.file_name()
                .map(|name| name.to_string_lossy().into_owned())
        })
        .unwrap_or_else(|| "unknown".into());
    #[cfg(target_os = "linux")]
    {
        format!(
            "pid={} tid={tid} thread={:?}",
            std::process::id(),
            std::thread::current().id()
        )
    }
    #[cfg(not(target_os = "linux"))]
    {
        format!(
            "pid={} thread={:?}",
            std::process::id(),
            std::thread::current().id()
        )
    }
}

impl LiveSession {
    fn emit(&self, generation: u64, kind: &str, payload: String) {
        (self.sink)(Event {
            session: self.control.id,
            generation,
            kind: kind.into(),
            payload,
        });
    }

    fn load(&mut self, generation: u64, source: String) -> Result<(), String> {
        if generation <= self.generation {
            return Err("UI generation must increase".into());
        }
        let result = super::compile_source(&source)?;
        let definition = result
            .component("CampyPreview")
            .ok_or("Missing exported CampyPreview component")?;
        let candidate = definition.create().map_err(|e| e.to_string())?;
        if let Some(old) = &self.instance {
            let new_properties: HashMap<_, _> = definition.properties().collect();
            for (name, kind) in old.definition().properties() {
                if new_properties.get(&name) == Some(&kind) {
                    if let Ok(value) = old.get_property(&name) {
                        candidate
                            .set_property(&name, value)
                            .map_err(|e| e.to_string())?;
                    }
                }
            }
            candidate.window().set_size(old.window().size());
        }
        for name in definition.callbacks() {
            let sink = self.sink.clone();
            let id = self.control.id;
            let kind = format!("callback:{name}");
            candidate
                .set_callback(&name, move |arguments| {
                    let payload = match arguments.first() {
                        Some(Value::String(text)) => text.to_string(),
                        Some(Value::Bool(value)) => value.to_string(),
                        Some(Value::Number(number)) => number_text(*number),
                        _ => String::new(),
                    };
                    sink(Event {
                        session: id,
                        generation,
                        kind: kind.clone(),
                        payload,
                    });
                    Value::Void
                })
                .map_err(|e| e.to_string())?;
        }
        let control = self.control.clone();
        candidate.window().on_close_requested(move || {
            let _ =
                control
                    .close_reason
                    .compare_exchange(0, 4, Ordering::AcqRel, Ordering::Acquire);
            slint::CloseRequestResponse::KeepWindowShown
        });
        candidate.show().map_err(|e| e.to_string())?;
        if let Some(old) = self.instance.replace(candidate) {
            let _ = old.hide();
        }
        self.generation = generation;
        self.emit(generation, "ui-loaded", thread_detail());
        Ok(())
    }

    fn execute(&mut self, command: Command) -> Result<(), String> {
        if let Command::LoadUi(generation, source) = command {
            return self.load(generation, source);
        }
        if command.generation() != self.generation {
            return Err("Stale UI generation".into());
        }
        let instance = self.instance.as_ref().ok_or("No UI is loaded")?;
        match command {
            Command::SetText(_, name, text) => instance
                .set_property(&name, Value::String(text.into()))
                .map_err(|e| e.to_string())?,
            Command::SetBool(_, name, value) => instance
                .set_property(&name, Value::Bool(value))
                .map_err(|e| e.to_string())?,
            Command::SetInt(_, name, value) => instance
                .set_property(&name, Value::Number(value as f64))
                .map_err(|e| e.to_string())?,
            Command::SetModel(_, name, items) => {
                let values: Vec<Value> = items
                    .into_iter()
                    .map(prop_value)
                    .collect::<Result<_, String>>()?;
                instance
                    .set_property(&name, Value::Model(ModelRc::new(VecModel::from(values))))
                    .map_err(|e| e.to_string())?
            }
            Command::SetColor(_, name, color) => instance
                .set_property(
                    &name,
                    Value::Brush(slint::Brush::SolidColor(parse_hex(&color)?)),
                )
                .map_err(|e| e.to_string())?,
            Command::ReadText(_, name) => {
                let value = instance.get_property(&name).map_err(|e| e.to_string())?;
                let Value::String(text) = value else {
                    return Err("Property is not a string".into());
                };
                self.emit(
                    self.generation,
                    &format!("property:{name}"),
                    text.to_string(),
                );
            }
            Command::Resize(_, width, height) => instance
                .window()
                .set_size(slint::LogicalSize::new(width as f32, height as f32)),
            Command::Snapshot(_, path) => {
                let image = instance
                    .window()
                    .take_snapshot()
                    .map_err(|e| e.to_string())?;
                let file = std::fs::File::create(&path).map_err(|e| e.to_string())?;
                let mut encoder = png::Encoder::new(file, image.width(), image.height());
                encoder.set_color(png::ColorType::Rgba);
                encoder.set_depth(png::BitDepth::Eight);
                encoder
                    .write_header()
                    .map_err(|e| e.to_string())?
                    .write_image_data(image.as_bytes())
                    .map_err(|e| e.to_string())?;
                self.emit(self.generation, "snapshot-saved", path);
            }
            #[cfg(feature = "ui-testing")]
            Command::TestInput(_, input) => {
                use slint::platform::{PointerEventButton, WindowEvent};
                let window = instance.window();
                window
                    .dispatch_event_with_result(WindowEvent::WindowActiveChanged(true))
                    .map_err(|e| e.to_string())?;
                let events = match input {
                    TestInput::Click(x, y) => {
                        let position = slint::LogicalPosition::new(x, y);
                        vec![
                            WindowEvent::PointerMoved { position },
                            WindowEvent::PointerPressed {
                                position,
                                button: PointerEventButton::Left,
                            },
                            WindowEvent::PointerReleased {
                                position,
                                button: PointerEventButton::Left,
                            },
                        ]
                    }
                    TestInput::Text(text) => text
                        .chars()
                        .flat_map(|character| {
                            let text: slint::SharedString = character.to_string().into();
                            [
                                WindowEvent::KeyPressed { text: text.clone() },
                                WindowEvent::KeyReleased { text },
                            ]
                        })
                        .collect(),
                    TestInput::KeyCombo(keys) => {
                        use slint::platform::Key;
                        let keys: Vec<slint::SharedString> = keys
                            .into_iter()
                            .map(|key| match key.as_str() {
                                "Control" => Key::Control.into(),
                                "Alt" => Key::Alt.into(),
                                "F4" => Key::F4.into(),
                                "F10" => Key::F10.into(),
                                "Escape" => Key::Escape.into(),
                                "Return" => Key::Return.into(),
                                "DownArrow" => Key::DownArrow.into(),
                                _ => key.into(),
                            })
                            .collect();
                        keys.iter()
                            .cloned()
                            .map(|text| WindowEvent::KeyPressed { text })
                            .chain(
                                keys.iter()
                                    .rev()
                                    .cloned()
                                    .map(|text| WindowEvent::KeyReleased { text }),
                            )
                            .collect()
                    }
                    TestInput::Close => vec![WindowEvent::CloseRequested],
                };
                for event in events {
                    window
                        .dispatch_event_with_result(event)
                        .map_err(|e| e.to_string())?;
                }
            }
            Command::LoadUi(..) => unreachable!(),
        }
        Ok(())
    }
}

fn run(receiver: Receiver<(u64, Command)>, shared: Arc<Shared>) -> Result<(), String> {
    // The pinned Winit backend explicitly sets with_any_thread(true) on Linux and Windows.
    // This adapter never relies on a scheduler or dirty scheduler being the UI thread.
    slint::BackendSelector::new()
        .backend_name("winit".into())
        .renderer_name("software".into())
        .select()
        .map_err(|e| e.to_string())?;
    let ui_thread = std::thread::current().id();
    #[cfg(target_os = "linux")]
    {
        let os_tid = std::fs::read_link("/proc/thread-self").map_err(|e| e.to_string())?;
        assert_ne!(
            os_tid.file_name().unwrap().to_string_lossy(),
            std::process::id().to_string()
        );
    }
    eprintln!(
        "Campy UI thread: {} backend=winit renderer=software",
        thread_detail()
    );
    shared.status.store(1, Ordering::Release);
    let mut sessions: HashMap<u64, LiveSession> = HashMap::new();
    let timer = Timer::default();
    timer.start(TimerMode::Repeated, Duration::from_millis(8), move || {
        assert_eq!(std::thread::current().id(), ui_thread);
        if let Ok(mut registrations) = shared.registrations.lock() {
            registrations.retain(|id, registration| {
                let reason = registration.control.close_reason.load(Ordering::Acquire);
                if reason != 0 {
                    let generation = if let Some(old) = sessions.remove(id) {
                        if let Some(instance) = old.instance {
                            let _ = instance.hide();
                        }
                        old.generation
                    } else {
                        0
                    };
                    (registration.sink)(Event {
                        session: *id,
                        generation,
                        kind: "closed".into(),
                        payload: format!("reason={reason}"),
                    });
                    false
                } else {
                    sessions.entry(*id).or_insert_with(|| {
                        let session = LiveSession {
                            control: registration.control.clone(),
                            sink: registration.sink.clone(),
                            instance: None,
                            generation: 0,
                        };
                        session.emit(
                            0,
                            "session-opened",
                            format!("pid={} thread={ui_thread:?}", std::process::id()),
                        );
                        session
                    });
                    true
                }
            });
        }
        // Bound work per iteration so queued commands do not starve native input.
        for _ in 0..8 {
            let Ok((id, command)) = receiver.try_recv() else {
                break;
            };
            // A session can be registered and receive its first command while
            // this loop is running (e.g. while compiling another session's UI).
            // The registry pass above has already run for this tick, so create
            // the live session on demand instead of dropping the command.
            if !sessions.contains_key(&id) {
                if let Ok(registrations) = shared.registrations.lock() {
                    if let Some(registration) = registrations.get(&id) {
                        let session = LiveSession {
                            control: registration.control.clone(),
                            sink: registration.sink.clone(),
                            instance: None,
                            generation: 0,
                        };
                        session.emit(
                            0,
                            "session-opened",
                            format!("pid={} thread={ui_thread:?}", std::process::id()),
                        );
                        sessions.insert(id, session);
                    }
                }
            }
            if let Some(session) = sessions.get_mut(&id) {
                if session.control.close_reason.load(Ordering::Acquire) != 0 {
                    continue;
                }
                let generation = command.generation();
                if let Err(error) = session.execute(command) {
                    session.emit(generation, "command-failed", error);
                }
            }
        }
    });
    slint::run_event_loop_until_quit().map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn callback_numbers_are_forwarded_without_a_fraction() {
        assert_eq!(number_text(42.0), "42");
        assert_eq!(number_text(-7.0), "-7");
        assert_eq!(number_text(1.5), "1.5");
    }

    #[test]
    fn rejects_oversized_and_invalid_commands_before_enqueue() {
        assert!(
            Command::LoadUi(1, "x".repeat(MAX_SOURCE_BYTES + 1))
                .validate()
                .is_err()
        );
        assert!(Command::Resize(1, 0, 100).validate().is_err());
        assert!(Command::ReadText(0, "query".into()).validate().is_err());
    }

    #[test]
    fn full_queue_does_not_prevent_cleanup() {
        let (sender, _receiver) = mpsc::sync_channel(1);
        let session = Session {
            control: Arc::new(Control {
                id: 1,
                close_reason: AtomicU8::new(0),
            }),
            sender,
            shared: Arc::new(Shared {
                status: AtomicU8::new(1),
                registrations: Mutex::new(HashMap::new()),
            }),
        };
        assert!(session.submit(Command::ReadText(1, "query".into())).is_ok());
        assert!(
            session
                .submit(Command::ReadText(1, "query".into()))
                .unwrap_err()
                .contains("full")
        );
        session.close(2);
        assert!(
            session
                .submit(Command::ReadText(1, "query".into()))
                .unwrap_err()
                .contains("closed")
        );
    }
}
