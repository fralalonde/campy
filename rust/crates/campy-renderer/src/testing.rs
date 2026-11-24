//! Headless smoke driver (`ui-testing` feature).
//!
//! The same zgui application runs under `zgui-platform-headless` instead of
//! winit. The UI thread owns the harness (zgui's runtime is single-threaded)
//! and executes test operations enqueued by the NIF: pump the virtual clock
//! (which fires the command-drain timers), deliver scripted surface events,
//! resize. This replaces protocol v1's `dispatch_event_with_result`
//! injection, which the winit path has no equivalent of.
//!
//! Calls are asynchronous by design: the BEAM smoke submits commands, asks
//! for a pump, then waits for the completion events (`ui-loaded`,
//! `read:<id>:<key>`, …) that the pump produced.

use std::rc::Rc;
use std::sync::mpsc::{SyncSender, TrySendError, sync_channel};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

use zgui::geom::{Css, CssPx, DevicePx, Point, Size};
use zgui::platform::{SurfaceEvent, SurfaceId};
use zgui::prelude::*;
use zgui::vocab::{
    Key, KeyEvent, KeyState, Modifiers, PhysicalKey, PointerAction, PointerEvent, PointerId,
    PointerKind, Timestamp,
};
use zgui_platform_headless::Harness;

use crate::sessions::ThreadState;

/// What the smoke suite asks the UI thread to do to the harness.
enum TestOp {
    Pump(u64),
    Pointer(String, f32, f32),
    Resize(f32, f32),
    /// A key press: name (named key or single character), modifiers.
    Key(String, bool, bool),
    /// The window's rendered rows, as stable text (one per surface).
    Dump,
}

struct Reply {
    pump_surfaces: u64,
    dump: Vec<String>,
}

/// A renderer that presents nothing: the headless platform has no device,
/// and the smoke suite asserts on events, not pixels.
pub struct NullRenderer {
    target: Option<zgui::render::RenderTarget>,
    atlas: zgui::atlas::MemorySink,
}

impl zgui::render::Renderer for NullRenderer {
    fn capabilities(&self) -> zgui::render::RenderCapabilities {
        zgui::render::RenderCapabilities::MINIMAL
    }

    fn configure(&mut self, target: zgui::render::RenderTarget) {
        self.target = Some(target);
    }

    fn target(&self) -> Option<zgui::render::RenderTarget> {
        self.target
    }

    fn draw(
        &mut self,
        _scene: &zgui::scene::Scene,
        _damage: &zgui::bits::DamageSet,
    ) -> zgui::render::FrameOutcome {
        zgui::render::FrameOutcome::Presented(zgui::render::FrameStats {
            draw_calls: 0,
            vector_passes: 0,
            damage_px: 0,
            bytes_uploaded: 0,
            memory: zgui::render::MemoryReport::default(),
        })
    }

    fn texture_sink(&mut self) -> &mut dyn zgui::atlas::TextureSink {
        &mut self.atlas
    }

    fn register_external(
        &mut self,
        _texture: zgui::render::ExternalTexture,
    ) -> zgui::render::TextureHandle {
        zgui::render::TextureHandle(0)
    }

    fn release_external(&mut self, _handle: zgui::render::TextureHandle) {}

    fn memory(&self) -> zgui::render::MemoryReport {
        zgui::render::MemoryReport::default()
    }
}

/// The factory the headless application installs.
pub fn null_renderer_factory(
    _surface: &std::sync::Arc<dyn zgui::platform::Surface>,
    target: zgui::render::RenderTarget,
) -> Result<Box<dyn zgui::render::Renderer>, zgui::runtime::AppError> {
    use zgui::render::Renderer as _;
    let mut renderer = NullRenderer {
        target: None,
        atlas: zgui::atlas::MemorySink::default(),
    };
    renderer.configure(target);
    Ok(Box::new(renderer))
}

static TEST_QUEUE: OnceLock<SyncSender<TestOp>> = OnceLock::new();
static TEST_REPLY: OnceLock<Mutex<Vec<Reply>>> = OnceLock::new();

const QUEUE_CAP: usize = 256;

/// Runs the application headlessly; the UI thread then services the test
/// queue forever. Returns only on error (the process ends with the VM).
pub fn drive_headless(_ui: Rc<ThreadState>, runtime: zgui::runtime::Runtime) -> Result<(), String> {
    let (sender, receiver) = sync_channel::<TestOp>(QUEUE_CAP);
    let _ = TEST_QUEUE.set(sender);
    let _ = TEST_REPLY.get_or_init(|| Mutex::new(Vec::new()));

    let mut harness = Harness::new(runtime);
    harness.deliver_to_first(SurfaceEvent::Resized(Size::new(
        DevicePx(1200.0),
        DevicePx(800.0),
    )));
    harness.settle(64);
    // Event times must move with the virtual clock; a stale timestamp is
    // how a scripted click silently stops being a click.
    let mut event_time = Duration::from_millis(0);
    // Surface ids for targeted delivery (a session window may not be the
    // first surface; v1 parity is enough for the smoke to click the IDE
    // shell, which is the initial window).
    loop {
        let Ok(op) = receiver.recv() else {
            return Ok(());
        };
        let reply = match op {
            TestOp::Pump(milliseconds) => {
                event_time += Duration::from_millis(milliseconds);
                harness.advance(Duration::from_millis(milliseconds));
                harness.settle(64);
                Reply {
                    pump_surfaces: harness.platform().offscreens().len() as u64,
                    dump: Vec::new(),
                }
            }
            TestOp::Pointer(action, x, y) => {
                let action = match action.as_str() {
                    "move" => PointerAction::Moved,
                    "press" => PointerAction::Pressed,
                    "release" => PointerAction::Released,
                    other => {
                        push_reply(Reply {
                            pump_surfaces: 0,
                            dump: vec![format!("unknown pointer action {other}")],
                        });
                        continue;
                    }
                };
                event_time += Duration::from_millis(16);
                let timestamp = Timestamp::ORIGIN + event_time;
                let at = Point::new(CssPx(x), CssPx(y));
                let mut event = PointerEvent::mouse(at);
                if matches!(action, PointerAction::Pressed | PointerAction::Released) {
                    event.button = Some(zgui::vocab::PointerButton::Primary);
                }
                harness.deliver_to_first(SurfaceEvent::Pointer {
                    action,
                    event,
                    modifiers: Modifiers::NONE,
                    timestamp,
                });
                harness.settle(8);
                Reply {
                    pump_surfaces: 0,
                    dump: Vec::new(),
                }
            }
            TestOp::Resize(width, height) => {
                harness.deliver_to_first(SurfaceEvent::Resized(Size::new(
                    DevicePx(width),
                    DevicePx(height),
                )));
                harness.settle(64);
                Reply {
                    pump_surfaces: 0,
                    dump: Vec::new(),
                }
            }
            TestOp::Key(name, control, shift) => {
                event_time += Duration::from_millis(16);
                let timestamp = Timestamp::ORIGIN + event_time;
                let mut modifiers = Modifiers::NONE;
                if control {
                    modifiers = Modifiers::CONTROL;
                }
                if shift {
                    modifiers =
                        Modifiers::from_bits_truncate(modifiers.bits() | Modifiers::SHIFT.bits());
                }
                let key = match name.as_str() {
                    "enter" => Key::Named(NamedKey::Enter),
                    "escape" => Key::Named(NamedKey::Escape),
                    "delete" => Key::Named(NamedKey::Delete),
                    "f4" => Key::Named(NamedKey::F4),
                    "f6" => Key::Named(NamedKey::F6),
                    "f7" => Key::Named(NamedKey::F7),
                    "f10" => Key::Named(NamedKey::F10),
                    other => Key::Character(other.to_owned().into()),
                };
                let key_without_modifiers = key.clone();
                let event = KeyEvent {
                    key: key.clone(),
                    key_without_modifiers,
                    physical: PhysicalKey::Unidentified(0),
                    location: zgui::vocab::KeyLocation::Standard,
                    repeat: false,
                };
                harness.deliver_to_first(SurfaceEvent::Key {
                    state: KeyState::Pressed,
                    event,
                    modifiers,
                    timestamp,
                });
                harness.settle(8);
                Reply {
                    pump_surfaces: 0,
                    dump: Vec::new(),
                }
            }
            TestOp::Dump => {
                let lines: Vec<String> = harness
                    .app()
                    .windows()
                    .iter()
                    .map(|window| {
                        let controls = window.nodes_with_class("campy-control").len();
                        let button = window
                            .box_with_class("campy-widget-button")
                            .map(|rect| {
                                format!(
                                    "{} {} {} {}",
                                    rect.origin.x.0,
                                    rect.origin.y.0,
                                    rect.size.width.0,
                                    rect.size.height.0
                                )
                            })
                            .unwrap_or_else(|| "NONE".into());
                        format!("controls={controls} button {button}")
                    })
                    .collect();
                eprintln!("CAMPY DUMP: {lines:?}");
                Reply {
                    pump_surfaces: 0,
                    dump: lines,
                }
            }
            _ => Reply {
                pump_surfaces: 0,
                dump: harness
                    .app()
                    .windows()
                    .iter()
                    .map(|window| {
                        let controls = window.nodes_with_class("campy-control").len();
                        let button = window
                            .box_with_class("campy-button")
                            .map(|rect| {
                                format!(
                                    "button rect {} {} {} {}",
                                    rect.origin.x.0,
                                    rect.origin.y.0,
                                    rect.size.width.0,
                                    rect.size.height.0
                                )
                            })
                            .unwrap_or_else(|| "button rect NONE".into());
                        format!("window controls={controls} {button}")
                    })
                    .collect(),
            },
        };
        push_reply(reply);
    }
}

fn push_reply(reply: Reply) {
    if let Some(cell) = TEST_REPLY.get() {
        if let Ok(mut replies) = cell.lock() {
            replies.push(reply);
            let excess = replies.len().saturating_sub(QUEUE_CAP);
            if excess > 0 {
                replies.drain(..excess);
            }
        }
    }
}

fn enqueue(op: TestOp) -> Result<(), String> {
    let Some(queue) = TEST_QUEUE.get() else {
        return Err("Headless driver is not running".into());
    };
    queue.try_send(op).map_err(|error| match error {
        TrySendError::Full(_) => "Test queue is full; retry later".into(),
        TrySendError::Disconnected(_) => "UI runtime is unavailable".into(),
    })
}

/// Asks the UI thread to advance the virtual clock (firing the command
/// drain) and settle. Returns immediately; wait on the events it produces.
pub fn test_pump(milliseconds: u64) -> Result<u64, String> {
    enqueue(TestOp::Pump(milliseconds))?;
    Ok(0)
}

/// Asks the UI thread to deliver a pointer event at CSS-pixel window
/// coordinates. `"click"` sends the whole press/release triple.
pub fn test_pointer(action: &str, x: f32, y: f32) -> Result<(), String> {
    if action == "click" {
        enqueue(TestOp::Pointer("move".into(), x, y))?;
        enqueue(TestOp::Pointer("press".into(), x, y))?;
        enqueue(TestOp::Pointer("release".into(), x, y))?;
        return Ok(());
    }
    enqueue(TestOp::Pointer(action.into(), x, y))
}

/// Asks the UI thread to deliver a key press (`"s"`, `"f6"`, `"delete"`)
/// with optional control/shift modifiers.
pub fn test_key(name: &str, control: bool, shift: bool) -> Result<(), String> {
    enqueue(TestOp::Key(name.into(), control, shift))
}

/// Asks the UI thread to deliver a window resize.
pub fn test_resize(width: f32, height: f32) -> Result<(), String> {
    enqueue(TestOp::Resize(width, height))
}

/// Debug readout of the headless windows (control counts, geometry).
pub fn test_dump() -> Result<Vec<String>, String> {
    enqueue(TestOp::Dump)?;
    Ok(Vec::new())
}

/// The dump replies accumulated so far (test-side probe).
pub fn test_dump_replies() -> Result<Vec<String>, String> {
    let Some(cell) = TEST_REPLY.get() else {
        return Err("Headless driver is not running".into());
    };
    let replies = cell.lock().map_err(|_| "reply log poisoned".to_string())?;
    Ok(replies
        .iter()
        .flat_map(|reply| reply.dump.iter().cloned())
        .collect())
}
