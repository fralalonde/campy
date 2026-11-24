//! `ControlDesc` → zgui views.
//!
//! One function per control kind; every control registers its live signals
//! in the session host so later bridge ops (`SetText`, `SetModel`,
//! `SetGeometry`, …) address it by id without rebuilding the document.
//! All event emission goes through [`Host::emit`] as protocol-v2 kinds.

use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::rc::Rc;
use std::sync::Arc;

use zgui::elements::{r#box, text};
use zgui::geom::{Css, CssPx, Point};
use zgui::prelude::*;
use zgui::view::{AnyView, AttrName, ClassName, events};
use zgui_editor::{EditorEvent, EditorHandle, EditorProps, LanguageConfig, LanguageRegistry};
use zgui_terminal::TerminalProps;
use zgui_ui::prelude::*;

use crate::wire::{ControlDesc, PropValue, UiDocument};

/// The BEAM-facing event channel (session, generation, kind, payload).
pub type EventSink = Arc<dyn Fn(u64, u64, String, String) + Send + Sync>;

/// Everything the control builders and the command applier share about one
/// session window. Lives on the UI thread only.
pub struct Host {
    pub session: u64,
    pub generation: Cell<u64>,
    /// Set at registration; a placeholder until then (initial window).
    sink: RefCell<EventSink>,
    /// The current UI document; `LoadUi` writes it and the window's
    /// reactive hole rebuilds incrementally.
    pub document: RwSignal<Option<UiDocument>, LocalStorage>,
    /// Live per-control signals, refilled on every document build.
    pub controls: RefCell<HashMap<u64, ControlSignals>>,
    /// Live editor handles (`memo` / `code_editor` kinds).
    pub editors: RefCell<HashMap<u64, EditorHandle>>,
    /// Live console feeds (`console` kind): AppendConsole bytes go here.
    pub consoles: RefCell<HashMap<u64, flume::Sender<Vec<u8>>>>,
    /// The current generation, mirrored for threads the sink may be
    /// called from (console input pumps).
    pub live_generation: std::sync::Arc<std::sync::atomic::AtomicU64>,
    /// This window's handle once the view is running (`use_window`).
    pub window: RefCell<Option<zgui::runtime::windows::WindowHandle>>,
    /// The NIF-visible session flag (close reasons ride it, v1 rule:
    /// cleanup survives a full queue).
    pub(crate) control: RefCell<Option<std::sync::Arc<crate::sessions::Control>>>,
}

impl Host {
    pub fn new(session: u64, sink: EventSink) -> Rc<Self> {
        Rc::new(Self {
            session,
            generation: Cell::new(0),
            sink: RefCell::new(sink),
            document: RwSignal::new_local(None),
            controls: RefCell::new(HashMap::new()),
            editors: RefCell::new(HashMap::new()),
            consoles: RefCell::new(HashMap::new()),
            live_generation: std::sync::Arc::new(std::sync::atomic::AtomicU64::new(0)),
            window: RefCell::new(None),
            control: RefCell::new(None),
        })
    }

    /// The registration's control flag, once the NIF registers us.
    pub(crate) fn adopt_control(&self, control: std::sync::Arc<crate::sessions::Control>) {
        *self.control.borrow_mut() = Some(control);
    }

    /// Whether a registration has been adopted (the sink arrived).
    pub fn adopted(&self) -> bool {
        // The placeholder host is swapped for the registered one, so this
        // only ever asks the real one.
        self.control.borrow().is_some()
    }

    /// The close reason the NIF side marked, if any.
    pub fn close_reason(&self) -> Option<u8> {
        self.control
            .borrow()
            .as_ref()
            .map(|control| {
                control
                    .close_reason
                    .load(std::sync::atomic::Ordering::Acquire)
            })
            .filter(|reason| *reason != 0)
    }

    /// The window's X button: close through the normal reap path so the
    /// BEAM sees `closed` with reason 4 (v1 parity).
    pub fn request_close(&self) {
        if let Some(control) = self.control.borrow().as_ref() {
            control.mark_close(4);
        }
    }

    /// The initial window's sink arrives with its registration.
    pub fn adopt_sink(&self, sink: EventSink) {
        *self.sink.borrow_mut() = sink;
    }

    fn send(&self, kind: String, payload: String) {
        (self.sink.borrow())(self.session, self.generation.get(), kind, payload);
    }

    /// A control-scoped event: `control:<id>:<event>`.
    pub fn emit(&self, control: u64, event: &str, payload: impl Into<String>) {
        self.send(format!("control:{control}:{event}"), payload.into());
    }

    /// The sink + ids a non-UI thread (console pump) emits with.
    pub fn thread_sink(&self) -> (EventSink, u64, std::sync::Arc<std::sync::atomic::AtomicU64>) {
        (
            self.sink.borrow().clone(),
            self.session,
            self.live_generation.clone(),
        )
    }

    /// A control-scoped reply: `read:<id>:<key>`.
    pub fn emit_read(&self, control: u64, key: &str, payload: impl Into<String>) {
        self.send(format!("read:{control}:{key}"), payload.into());
    }

    /// A lifecycle or failure event, kind verbatim.
    pub fn emit_raw(&self, kind: &str, payload: impl Into<String>) {
        self.send(kind.into(), payload.into());
    }
}

/// The live, addressable state of one control. Signals are cheap handles;
/// the registry is rebuilt with the document.
#[derive(Clone)]
pub struct ControlSignals {
    pub text: RwSignal<String, LocalStorage>,
    pub checked: RwSignal<Checked, LocalStorage>,
    pub value: RwSignal<f64, LocalStorage>,
    pub progress: RwSignal<Option<f64>, LocalStorage>,
    pub model: RwSignal<Vec<PropValue>, LocalStorage>,
    pub rect: RwSignal<(f64, f64, f64, f64), LocalStorage>,
    pub enabled: RwSignal<bool, LocalStorage>,
    pub visible: RwSignal<bool, LocalStorage>,
}

fn checked_of(value: bool) -> Checked {
    if value { Checked::Yes } else { Checked::No }
}

fn prop_bool(desc: &ControlDesc, key: &str) -> Option<bool> {
    desc.prop(key).and_then(PropValue::boolean)
}

fn prop_string(desc: &ControlDesc, key: &str) -> Option<String> {
    desc.prop(key).and_then(PropValue::text).map(str::to_owned)
}

fn prop_model(desc: &ControlDesc) -> Vec<PropValue> {
    match desc.prop("model") {
        Some(PropValue::List(items)) => items.clone(),
        _ => Vec::new(),
    }
}

/// One model item's display text (`WireText` or `WireStruct(text, …)`).
pub fn item_text(items: &[PropValue], index: usize) -> String {
    items
        .get(index)
        .map(|item| match item {
            PropValue::Text(text) => text.clone(),
            PropValue::Struct(fields) => fields
                .iter()
                .find(|(name, _)| name == "text")
                .and_then(|(_, value)| value.text().map(str::to_owned))
                .unwrap_or_default(),
            other => {
                let text = crate::wire::prop_value_text(other);
                text
            }
        })
        .unwrap_or_default()
}

fn px(value: f64) -> String {
    if value.fract() == 0.0 {
        format!("{}px", value as i64)
    } else {
        format!("{value}px")
    }
}

/// Builds the whole window document: the themed root plus one wrapper per
/// top-level control.
pub fn build_document(doc: &UiDocument, host: &Rc<Host>) -> AnyView {
    host.controls.borrow_mut().clear();
    let children: Vec<AnyView> = doc
        .controls
        .iter()
        .map(|desc| AnyView::new(build_control(desc, host)))
        .collect();
    let root = r#box()
        .class("campy-root")
        .class("campy-free")
        .class(if doc.theme == "dark" {
            "campy-dark"
        } else {
            "campy-light"
        })
        .children(children);
    AnyView::new(root)
}

/// One control: a positioned wrapper carrying geometry/enabled/visible,
/// with the kind's widget inside (or children, for containers).
pub fn build_control(desc: &ControlDesc, host: &Rc<Host>) -> AnyView {
    let signals = ControlSignals {
        text: RwSignal::new_local(desc.text.clone()),
        checked: RwSignal::new_local(checked_of(prop_bool(desc, "checked").unwrap_or(false))),
        value: RwSignal::new_local(
            desc.prop("value")
                .and_then(PropValue::number)
                .unwrap_or(0.0),
        ),
        progress: RwSignal::new_local(Some(
            desc.prop("value")
                .and_then(PropValue::number)
                .unwrap_or(0.0),
        )),
        model: RwSignal::new_local(prop_model(desc)),
        rect: RwSignal::new_local((desc.x, desc.y, desc.w, desc.h)),
        enabled: RwSignal::new_local(desc.enabled),
        visible: RwSignal::new_local(desc.visible),
    };
    host.controls.borrow_mut().insert(desc.id, signals.clone());

    let rect = signals.rect.clone();
    let enabled = signals.enabled.clone();
    let visible = signals.visible.clone();
    let mut wrapper = r#box()
        .class("campy-control")
        .class(format!("campy-{}", desc.kind))
        .style_property("left", move || Some(px(rect.get().0)))
        .style_property("top", move || Some(px(rect.get().1)))
        .style_property("width", move || Some(px(rect.get().2)))
        .style_property("height", move || Some(px(rect.get().3)))
        .style_property("display", move || {
            if visible.get() {
                None
            } else {
                Some("none".to_owned())
            }
        })
        .class_toggle(ClassName::new("campy-disabled"), move || !enabled.get());

    match desc.kind.as_str() {
        "panel" | "group" | "surface" => {
            let children: Vec<AnyView> = desc
                .children
                .iter()
                .map(|child| AnyView::new(build_control(child, host)))
                .collect();
            if desc.kind == "surface" {
                // The designer surface: engine-computed grid + raw pointer
                // phases forwarded to the BEAM (which hit-tests from the
                // form model). Positions are window CSS pixels.
                let down_host = host.clone();
                let move_host = host.clone();
                let up_host = host.clone();
                let wheel_host = host.clone();
                let surface_id = desc.id;
                wrapper = wrapper
                    .on(events::POINTER_DOWN, move |cx| {
                        let position: Point<CssPx, Css> = cx.position;
                        down_host.emit_raw(
                            &format!("pointer:{surface_id}:down"),
                            format!("{};{}", position.x.0, position.y.0),
                        );
                    })
                    .on(events::POINTER_MOVE, move |cx| {
                        let position: Point<CssPx, Css> = cx.position;
                        move_host.emit_raw(
                            &format!("pointer:{surface_id}:move"),
                            format!("{};{}", position.x.0, position.y.0),
                        );
                    })
                    .on(events::POINTER_UP, move |cx| {
                        let position: Point<CssPx, Css> = cx.position;
                        up_host.emit_raw(
                            &format!("pointer:{surface_id}:up"),
                            format!("{};{}", position.x.0, position.y.0),
                        );
                    })
                    .on(events::WHEEL, move |cx| {
                        let position: Point<CssPx, Css> = cx.position;
                        let (dx, dy) = wheel_delta(cx);
                        wheel_host.emit_raw(
                            &format!("pointer:{surface_id}:wheel"),
                            format!("{dx:.1};{dy:.1};{};{}", position.x.0, position.y.0),
                        );
                    })
                    .child(r#box().class("campy-surface-grid"));
            }
            let layout = prop_string(desc, "layout").unwrap_or_else(|| "free".into());
            wrapper = match layout.as_str() {
                "column" => wrapper.class("campy-col"),
                "row" => wrapper.class("campy-row"),
                _ => wrapper.class("campy-free"),
            };
            AnyView::new(wrapper.children(children))
        }
        _ => AnyView::new(wrapper.child(widget(desc, host, &signals))),
    }
}

fn wheel_delta(event: &zgui::vocab::WheelEvent) -> (f64, f64) {
    use zgui::vocab::ScrollDelta;
    match event.delta {
        ScrollDelta::Lines { x, y } => (x as f64, y as f64),
        ScrollDelta::Pixels(delta) => (delta.width.0 as f64, delta.height.0 as f64),
        _ => (0.0, 0.0),
    }
}

/// The kind's widget. Handlers only capture cheap clones.
fn widget(desc: &ControlDesc, host: &Rc<Host>, signals: &ControlSignals) -> AnyView {
    let id = desc.id;
    let host = host.clone();
    let text = signals.text.clone();
    match desc.kind.as_str() {
        "label" => AnyView::new(text_element(move || text.get())),

        // A campy-styled base control rather than zgui-ui's Button: the
        // base element is the path verified end to end through real
        // surface input; zgui-ui components get their own live-window A/B
        // in Z2.2 (their own tests dispatch through the component testkit,
        // not the platform).
        "button" | "menu" => AnyView::new(
            zgui::elements::control()
                .class("campy-widget-button")
                .tabindex(Focus::Sequential)
                .on(events::CLICK, move |_| host.emit(id, "clicked", ""))
                .child(move || text.get()),
        ),

        "edit" => {
            let placeholder = prop_string(desc, "placeholder").unwrap_or_default();
            let read_only = prop_bool(desc, "read-only").unwrap_or(false);
            AnyView::new(view! {
                Input(
                    value = text,
                    placeholder = placeholder,
                    read_only = read_only,
                    on_change = UnsyncCallback::new(move |value: String| host.emit(id, "edited", value)),
                ) {}
            })
        }

        "checkbox" | "radio" => {
            let checked = signals.checked.clone();
            AnyView::new(
                zgui::elements::row()
                    .class("campy-check-row")
                    .child(view! {
                        Checkbox(
                            checked = checked,
                            on_change = UnsyncCallback::new(move |value: Checked| {
                                host.emit(id, "toggled", matches!(value, Checked::Yes).to_string())
                            }),
                        ) {}
                    })
                    .child(text_element(move || text.get())),
            )
        }

        "combo" | "menu-list" => {
            let model = signals.model.clone();
            AnyView::new(view! {
                Select(
                    value = text,
                    on_change = UnsyncCallback::new(move |value: String| host.emit(id, "selected", value)),
                ) {
                    {move || options(model.clone(), "campy-option")}
                }
            })
        }

        "list" => {
            let model = signals.model.clone();
            AnyView::new(view! {
                VirtualList(
                    count = Signal::derive_local(move || model.get().len()),
                    row_size = 24.0,
                    row = move |index: usize| {
                        let items = model.get();
                        view_row(item_text(&items, index))
                    },
                )
            })
        }

        "slider" => {
            let value = signals.value.clone();
            let minimum = desc
                .prop("minimum")
                .and_then(PropValue::number)
                .unwrap_or(0.0);
            let maximum = desc
                .prop("maximum")
                .and_then(PropValue::number)
                .unwrap_or(100.0);
            AnyView::new(view! {
                Slider(
                    value = value,
                    default_value = minimum,
                    max = maximum,
                    min = minimum,
                    on_change = UnsyncCallback::new(move |value: f64| host.emit(id, "changed", format!("{value}"))),
                ) {}
            })
        }

        "progress" => {
            let progress = signals.progress.clone();
            let maximum = desc
                .prop("maximum")
                .and_then(PropValue::number)
                .unwrap_or(100.0);
            AnyView::new(view! {
                Progress(value = progress, max = maximum) {}
            })
        }

        "picture" => {
            let source = prop_string(desc, "source").unwrap_or_default();
            let mut image = zgui::elements::image()
                .attribute(AttrName::new("src"), Some(source))
                .class("campy-picture");
            if let Some(fit) = prop_string(desc, "fit") {
                image = image.style_property("object-fit", Some(fit));
            }
            AnyView::new(image)
        }

        "memo" | "code_editor" => {
            let language = prop_string(desc, "language");
            let handle_slot: Rc<RefCell<Option<EditorHandle>>> = Rc::new(RefCell::new(None));
            let ready_slot = handle_slot.clone();
            let ready_host = host.clone();
            let event_host = host.clone();
            let initial = desc.text.clone();
            let registry = gleam_registry();
            let editor = view! {
                Editor(
                    text = initial,
                    language = language,
                    registry = registry,
                    on_ready = Box::new(move |handle: EditorHandle| {
                        *ready_slot.borrow_mut() = Some(handle.clone());
                        ready_host.editors.borrow_mut().insert(id, handle);
                    }) as Box<dyn Fn(EditorHandle)>,
                    on_event = Box::new(move |event: EditorEvent| {
                        if let EditorEvent::Edited { .. } = event {
                            if let Some(handle) = handle_slot.borrow().as_ref() {
                                event_host.emit_raw(
                                    &format!("editor:{id}:changed"),
                                    handle.query(|snapshot| snapshot.rope().to_string()),
                                );
                            }
                        }
                    }) as Box<dyn Fn(EditorEvent)>,
                    class = "campy-editor",
                ) {}
            };
            AnyView::new(editor)
        }

        "console" => {
            // A real terminal over channels: AppendConsole bytes arrive on
            // `output`; the terminal's keyboard flows back on `input`, and
            // a pump thread forwards it to the BEAM as console input. ANSI
            // escapes pass through, so preview logs render colored.
            let (feed, output) = flume::unbounded::<Vec<u8>>();
            let (input, keyboard) = flume::unbounded::<Vec<u8>>();
            host.consoles.borrow_mut().insert(id, feed);
            let (sink, session, generation) = host.thread_sink();
            std::thread::spawn(move || {
                while let Ok(bytes) = keyboard.recv() {
                    let text = String::from_utf8_lossy(&bytes)
                        .trim_end_matches(['\r', '\n'])
                        .to_string();
                    (sink)(
                        session,
                        generation.load(std::sync::atomic::Ordering::Acquire),
                        format!("console:{id}:input"),
                        text,
                    );
                }
            });
            let terminal = view! {
                Terminal(
                    transport = zgui_terminal::transport::Channels::new(input, output),
                    class = "campy-console",
                ) {}
            };
            AnyView::new(terminal)
        }

        _other => {
            let kind = desc.kind.clone();
            AnyView::new(
                r#box()
                    .class("campy-unknown")
                    .child(text_element(move || format!("[{kind}] {}", text.get()))),
            )
        }
    }
}

fn text_element(
    value: impl Fn() -> String + 'static,
) -> zgui::elements::Element<zgui::elements::Text> {
    text().child(value)
}

fn view_row(label: String) -> zgui::elements::Element<zgui::elements::Box_> {
    r#box().class("campy-list-row").child(label)
}

fn options(model: RwSignal<Vec<PropValue>, LocalStorage>, class: &str) -> AnyView {
    let items = model.get();
    let mut column = zgui::elements::column().class(class);
    for (index, _item) in items.iter().enumerate() {
        column = column.child(view_row(item_text(&items, index)));
    }
    AnyView::new(column)
}

/// The application's language registry: the bundled set plus the Gleam
/// grammar (tree-sitter-gleam exposes the ABI-stable `LanguageFn`, which
/// tree-sitter 0.26 converts to its `Language`).
fn gleam_registry() -> Option<LanguageRegistry> {
    use std::sync::OnceLock;
    static REGISTRY: OnceLock<Option<LanguageRegistry>> = OnceLock::new();
    Some(
        REGISTRY
            .get_or_init(|| {
                let registry = LanguageRegistry::new().with_bundled();
                registry.register(LanguageConfig {
                    name: "gleam".into(),
                    language: tree_sitter::Language::from(tree_sitter_gleam::LANGUAGE),
                    highlight_query: tree_sitter_gleam::HIGHLIGHT_QUERY.to_owned(),
                    injections_query: None,
                    extensions: vec!["gleam".into()],
                });
                Some(registry)
            })
            .clone()
            .expect("the registry is always built"),
    )
}
