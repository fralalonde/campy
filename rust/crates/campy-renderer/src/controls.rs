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
use zgui::view::{AnyView, AttrName, ClassName, NodeRef, WindowShortcut, events};
use zgui::vocab::{Key, KeyEvent, Modifiers};
use zgui_editor::{
    Decoration, EditorEvent, EditorHandle, EditorProps, LanguageConfig, LanguageRegistry,
    UnderlineStyle,
};
use zgui_terminal::TerminalProps;
use zgui_ui::prelude::*;

use crate::wire::{ControlDesc, PropValue, UiDocument};

/// A popup's row height, padding and width, in CSS pixels.
const MENU_ROW: f64 = 26.0;
const MENU_SEPARATOR: f64 = 9.0;
const MENU_PAD: f64 = 4.0;
const MENU_WIDTH: f64 = 260.0;

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
    /// reactive hole rebuilds incrementally. Reference-counted rather than
    /// scope-owned: a host swapped in by a deferred load is built in the
    /// command drain, outside any window's scope, and a `new_local` signal
    /// made there is disposed before the window it belongs to is built.
    pub document: zgui::reactive::ArcRwSignal<Option<UiDocument>>,
    /// Live per-control signals, refilled on every document build.
    pub controls: RefCell<HashMap<u64, ControlSignals>>,
    /// Live editor handles (`memo` / `code_editor` kinds).
    pub editors: RefCell<HashMap<u64, EditorHandle>>,
    /// Live console feeds (`console` kind): AppendConsole bytes go here.
    pub consoles: RefCell<HashMap<u64, flume::Sender<Vec<u8>>>>,
    /// Whether this session's window came through the runtime's
    /// deferred `windows.open` flow (their reactive rebuilds do not fire;
    /// loads swap the window instead — ADR 0003).
    pub deferred_window: Cell<bool>,
    /// The current generation, mirrored for threads the sink may be
    /// called from (console input pumps).
    pub live_generation: std::sync::Arc<std::sync::atomic::AtomicU64>,
    /// This window's handle once the view is running (`use_window`).
    pub window: RefCell<Option<zgui::runtime::windows::WindowHandle>>,
    /// Whether the debug fullscreen request was made (`CAMPY_UI_FULLSCREEN`).
    pub fullscreen_done: Cell<bool>,
    /// The control whose popup is showing, by id (a `menu`'s items or a
    /// `combo`'s options). One at a time: opening another replaces it, and a
    /// press outside closes it. Plain state rather than a signal: a host may be
    /// built outside any window scope (a deferred load swaps one in from the
    /// drain), and a `new_local` signal made there is disposed with that scope.
    /// `popup_tick` is the signal, and it is made during the document build so
    /// it belongs to the window.
    pub popup: Cell<Option<u64>>,
    /// Each control's kind, for the popup to know what its rows are.
    pub kinds: RefCell<HashMap<u64, String>>,
    /// Bumped whenever `popup` changes; the popup redraws on it.
    pub popup_tick: RefCell<Option<RwSignal<u64, LocalStorage>>>,
    /// Absolute CSS rectangles of the document's controls, filled by each
    /// build. A popup is drawn at the document root, so it has to know where
    /// its trigger is on screen.
    pub rects: RefCell<HashMap<u64, (f64, f64, f64, f64)>>,
    /// The open popup's absolute rectangle, for the press-outside test.
    pub popup_rect: Cell<Option<(f64, f64, f64, f64)>>,
    /// Whether `CAMPY_UI_OPEN_MENU` has been honoured (one shot).
    pub popup_debugged: Cell<bool>,
    /// The window size last reported to the BEAM, in CSS pixels.
    pub last_size: Cell<(u32, u32)>,
    /// Set on a host whose window was closed by `swap_load` rather than by the
    /// user: its close hook must not close the session the replacement took
    /// over (the control is shared).
    pub window_swapped: Cell<bool>,
    /// Whether a one-line property field holds the focus. It owns the keys that
    /// move its caret and nothing else: Ctrl+Z, Ctrl+C and Ctrl+V keep working
    /// on the document, which is what a designer presses them for.
    pub field_focused: Cell<bool>,
    /// Whether the code editor or the terminal holds the focus. Those are real
    /// text editors with their own undo and clipboard, so they own the whole
    /// editing set. Booleans rather than counters: focus arriving in a field's
    /// inner elements fires more than one `in`, and a counter that drifts never
    /// comes back to zero — which silences every shortcut for the session.
    pub editor_focused: Cell<bool>,
    /// Whether this host's view has finished its first build. A document that
    /// arrives before that is loaded into the window being built (its dynamic
    /// child reads it); one that arrives after needs a swap, which is the
    /// deferred-window path ADR 0003 records.
    pub view_built: Cell<bool>,
    /// Whether the current document's controls have been built and registered.
    /// Commands that address a control wait for this instead of failing with
    /// "unknown control" against the window that is still mounting.
    pub document_ready: Cell<bool>,
    /// The effect that drains the queue when the BEAM hands the window work.
    /// Kept so the reactive scope owns it for the window's lifetime.
    pub work_effect: RefCell<Option<zgui::reactive::RenderEffect<()>>>,
    /// The effect that reports the window's size as it changes.
    pub size_effect: RefCell<Option<zgui::reactive::RenderEffect<()>>>,
    /// Armed only in a screenshot run: an idle window draws no frames, and a
    /// frame is what the snapshot is taken from.
    pub validation_tick: zgui::reactive::ArcRwSignal<u64>,
    pub validation_interval: RefCell<Option<zgui::view::time::IntervalHandle>>,
    /// Whether the wake model is in use (see `sessions::report_size`).
    pub shared: std::sync::Arc<crate::sessions::Shared>,
    /// The NIF-visible session flag (close reasons ride it, v1 rule:
    /// cleanup survives a full queue).
    pub(crate) control: RefCell<Option<std::sync::Arc<crate::sessions::Control>>>,
}

impl Host {
    pub fn new(
        session: u64,
        sink: EventSink,
        shared: std::sync::Arc<crate::sessions::Shared>,
    ) -> Rc<Self> {
        Rc::new(Self {
            session,
            generation: Cell::new(0),
            sink: RefCell::new(sink),
            document: zgui::reactive::ArcRwSignal::new(None),
            controls: RefCell::new(HashMap::new()),
            editors: RefCell::new(HashMap::new()),
            consoles: RefCell::new(HashMap::new()),
            deferred_window: Cell::new(false),
            live_generation: std::sync::Arc::new(std::sync::atomic::AtomicU64::new(0)),
            window: RefCell::new(None),
            fullscreen_done: Cell::new(false),
            popup: Cell::new(None),
            kinds: RefCell::new(HashMap::new()),
            popup_tick: RefCell::new(None),
            rects: RefCell::new(HashMap::new()),
            popup_rect: Cell::new(None),
            popup_debugged: Cell::new(false),
            last_size: Cell::new((0, 0)),
            window_swapped: Cell::new(false),
            field_focused: Cell::new(false),
            editor_focused: Cell::new(false),
            view_built: Cell::new(false),
            document_ready: Cell::new(false),
            work_effect: RefCell::new(None),
            size_effect: RefCell::new(None),
            validation_tick: zgui::reactive::ArcRwSignal::new(0),
            validation_interval: RefCell::new(None),
            shared,
            control: RefCell::new(None),
        })
    }

    /// The registration's control flag, once the NIF registers us.
    pub(crate) fn adopt_control(&self, control: std::sync::Arc<crate::sessions::Control>) {
        *self.control.borrow_mut() = Some(control);
    }

    /// The event channel, for the sessions layer's window swaps.
    pub fn sink_handle(&self) -> EventSink {
        self.sink.borrow().clone()
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

    /// Tells the popup that `popup` moved.
    fn bump_popup(&self) {
        if let Some(tick) = self.popup_tick.borrow().as_ref() {
            tick.update(|version| *version += 1);
        }
    }

    /// Subscribes to the popup's version and answers it.
    fn popup_version(&self) -> u64 {
        self.popup_tick
            .borrow()
            .as_ref()
            .map(|tick| tick.get())
            .unwrap_or(0)
    }

    /// Opens or closes the popup of `control`, replacing whatever was showing.
    fn toggle_popup(&self, control: u64) {
        let showing = self.popup.get();
        self.popup.set(if showing == Some(control) {
            None
        } else {
            Some(control)
        });
        self.bump_popup();
    }

    /// Closes the popup, if one is showing.
    fn close_popup(&self) {
        if self.popup.get().is_some() {
            self.popup.set(None);
            self.bump_popup();
        }
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
    // `source` arrives as `WireImage` from the Gleam emitter (protocol
    // §1.4) and as plain text from older descriptions; accept either.
    desc.prop(key).and_then(|value| match value {
        PropValue::Image(path) => Some(path.clone()),
        other => other.text().map(str::to_owned),
    })
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
            other => crate::wire::prop_value_text(other),
        })
        .unwrap_or_default()
}

/// One model item's `active` flag (`{text, id, active}` structs). A list that
/// carries no such field marks nothing, which is the plain list.
fn item_active(items: &[PropValue], index: usize) -> bool {
    items
        .get(index)
        .and_then(|item| match item {
            PropValue::Struct(fields) => fields
                .iter()
                .find(|(name, _)| name == "active")
                .and_then(|(_, value)| value.boolean()),
            _ => None,
        })
        .unwrap_or(false)
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
    // A build replaces every wrapper, so whatever held the focus went with the
    // old one.
    host.field_focused.set(false);
    host.editor_focused.set(false);
    if std::env::var_os("CAMPY_UI_TRACE").is_some() {
        eprintln!(
            "campy build_document theme={} roots={}",
            doc.theme,
            doc.controls.len()
        );
    }
    // The popup's signal belongs to this build (and so to the window), which is
    // what keeps it alive across a window swap: the host itself may not be.
    *host.popup_tick.borrow_mut() = Some(RwSignal::new_local(0_u64));
    host.controls.borrow_mut().clear();
    host.rects.borrow_mut().clear();
    for desc in &doc.controls {
        collect_rects(desc, 0.0, 0.0, &mut host.rects.borrow_mut());
        collect_kinds(desc, &mut host.kinds.borrow_mut());
    }
    if !host.popup_debugged.get() {
        host.popup_debugged.set(true);
        // A validation run cannot click yet on every desktop; this opens the
        // first menu so its popup can be screenshotted at startup.
        if std::env::var_os("CAMPY_UI_OPEN_MENU").is_some()
            && let Some(menu) = first_of_kind(&doc.controls, &["menu"])
        {
            host.popup.set(Some(menu));
        }
        if std::env::var_os("CAMPY_UI_OPEN_CHOICE").is_some()
            && let Some(choice) = first_of_kind(&doc.controls, &["combo", "menu-list"])
        {
            host.popup.set(Some(choice));
        }
    }
    let children: Vec<AnyView> = doc
        .controls
        .iter()
        .map(|desc| AnyView::new(build_control(desc, host)))
        .collect();
    let popup_host = host.clone();
    let key_host = host.clone();
    let close_host = host.clone();
    // Keys belong to the window, not to whatever happens to have focus: without
    // this registration the shell has no keyboard at all until a field is
    // clicked, which is why every shortcut was dead.
    let anchor = NodeRef::new();
    let shortcut_anchor = anchor;
    let registration =
        zgui::reactive::RenderEffect::new(move |previous: Option<Option<WindowShortcut>>| {
            drop(previous);
            shortcut_anchor.get();
            shortcut_anchor.window_shortcut()
        });
    zgui::reactive::on_cleanup_local(move || drop(registration));
    let root = r#box()
        .node_ref(anchor)
        .class("campy-root")
        .class("campy-free")
        .on(events::KEY_DOWN, move |cx| {
            let event: &KeyEvent = cx;
            if let Some(combo) = key_combo(&event.key_without_modifiers, cx.modifiers) {
                // A focused property field owns the keys that move its caret and
                // select its text; a focused editor owns the editing set too.
                // Everything else — including undo and the clipboard from a
                // property field — reaches the shell, because that is the
                // document the user is pressing Ctrl+Z about.
                let own = if key_host.field_focused.get() {
                    caret_combo(&combo)
                } else if key_host.editor_focused.get() {
                    editing_combo(&combo)
                } else {
                    false
                };
                if own {
                    return;
                }
                if pointer_log() {
                    eprintln!("key {combo}");
                }
                key_host.emit_raw("key", combo);
            }
        })
        .class(if doc.theme == "dark" {
            "campy-dark"
        } else {
            "campy-light"
        })
        .on(events::POINTER_DOWN, move |cx| {
            // A press outside the open popup closes it, the way a menu bar
            // behaves everywhere. Inside, it is the row's own click.
            let position: Point<CssPx, Css> = cx.position;
            let inside = close_host.popup_rect.get().is_some_and(|(x, y, w, h)| {
                let (px, py) = (position.x.0 as f64, position.y.0 as f64);
                px >= x && px <= x + w && py >= y && py <= y + h
            });
            if !inside {
                close_host.close_popup();
            }
        })
        .children(children)
        .child(move || popup_card(&popup_host));
    AnyView::new(root)
}

/// Records each control's absolute rectangle: the popup is drawn at the root,
/// so where its trigger sits cannot be read from the trigger itself.
fn collect_rects(
    desc: &ControlDesc,
    origin_x: f64,
    origin_y: f64,
    into: &mut HashMap<u64, (f64, f64, f64, f64)>,
) {
    let x = origin_x + desc.x;
    let y = origin_y + desc.y;
    into.insert(desc.id, (x, y, desc.w, desc.h));
    for child in &desc.children {
        collect_rects(child, x, y, into);
    }
}

/// Whether a model item is a separator, which the shell spells as an em dash.
fn is_separator(label: &str) -> bool {
    label.trim().is_empty() || label.trim() == "\u{2014}"
}

/// Splits a menu label from its shortcut: the model carries the old shell's
/// item titles, `Save    Ctrl+S`, so the shortcut is whatever follows a run of
/// two or more spaces.
fn split_shortcut(label: &str) -> (String, String) {
    let bytes = label.as_bytes();
    let mut index = 0;
    while index + 1 < bytes.len() {
        if bytes[index] == b' ' && bytes[index + 1] == b' ' {
            let name = label[..index].trim_end().to_owned();
            let shortcut = label[index..].trim().to_owned();
            return (name, shortcut);
        }
        index += 1;
    }
    (label.to_owned(), String::new())
}

/// The id of the first `menu` in the document (the validation knob's target).
/// Records each control's kind, so the popup knows whether its model is a menu
/// (separators and shortcuts) or a choice list (a check on the current value).
fn collect_kinds(desc: &ControlDesc, into: &mut HashMap<u64, String>) {
    into.insert(desc.id, desc.kind.clone());
    for child in &desc.children {
        collect_kinds(child, into);
    }
}

fn first_of_kind(controls: &[ControlDesc], kinds: &[&str]) -> Option<u64> {
    for desc in controls {
        if kinds.iter().any(|kind| *kind == desc.kind) {
            return Some(desc.id);
        }
        if let Some(found) = first_of_kind(&desc.children, kinds) {
            return Some(found);
        }
    }
    None
}

/// The open popup, or nothing: a menu's items or a choice list's options, one
/// `control()` row each, drawn at the document root above everything.
fn popup_card(host: &Rc<Host>) -> AnyView {
    let _version = host.popup_version();
    let Some(control) = host.popup.get() else {
        host.popup_rect.set(None);
        return AnyView::new(r#box());
    };
    let Some(&(x, y, trigger_w, h)) = host.rects.borrow().get(&control) else {
        return AnyView::new(r#box());
    };
    let is_menu = host
        .kinds
        .borrow()
        .get(&control)
        .is_some_and(|kind| kind == "menu");
    let (items, current) = {
        let controls = host.controls.borrow();
        let Some(signals) = controls.get(&control) else {
            return AnyView::new(r#box());
        };
        (signals.model.get(), signals.text.get())
    };
    // Separators are a rule, not a row: counting them at row height leaves a
    // band of empty panel under the last item.
    let height = items
        .iter()
        .enumerate()
        .map(|(index, _)| {
            let label = item_text(&items, index);
            if is_menu && is_separator(&label) {
                MENU_SEPARATOR
            } else {
                MENU_ROW
            }
        })
        .sum::<f64>()
        + MENU_PAD * 2.0;
    // A menu is wide enough for its shortcuts; a choice list matches the field
    // it drops from, so the two edges line up.
    let width = if is_menu {
        MENU_WIDTH
    } else {
        trigger_w.max(140.0)
    };
    // Below the trigger, unless that would run off the bottom of the window.
    let window_h = f64::from(host.last_size.get().1);
    let below = y + h + 2.0;
    let top = if window_h > 0.0 && below + height > window_h {
        (y - height - 2.0).max(0.0)
    } else {
        below
    };
    host.popup_rect.set(Some((x, top, width, height)));
    let mut card = r#box()
        .class(if is_menu {
            "campy-menu-popup"
        } else {
            "campy-choice-popup"
        })
        .style_property("left", Some(px(x)))
        .style_property("top", Some(px(top)))
        .style_property("width", Some(px(width)))
        .style_property("height", Some(px(height)));
    for (index, _) in items.iter().enumerate() {
        let label = item_text(&items, index);
        if is_menu && is_separator(&label) {
            card = card.child(r#box().class("campy-menu-separator"));
            continue;
        }
        let row_host = host.clone();
        let click_label = label.clone();
        let (name, shortcut) = if is_menu {
            split_shortcut(&label)
        } else {
            (label.clone(), String::new())
        };
        let chosen = !is_menu && label == current;
        let mut row = zgui::elements::control()
            .class("campy-menu-item")
            .class(if is_menu {
                "campy-menu-entry"
            } else {
                "campy-choice-entry"
            })
            .class_toggle(ClassName::new("campy-choice-on"), move || chosen)
            .tabindex(Focus::Sequential)
            .on(events::CLICK, move |_| {
                row_host.close_popup();
                row_host.emit(control, "selected", click_label.clone());
            });
        row = if is_menu {
            row.child(
                r#box()
                    .class("campy-menu-line")
                    .child(text().child(name))
                    .child(text().class("campy-menu-shortcut").child(shortcut)),
            )
        } else {
            row.child(
                r#box()
                    .class("campy-choice-row-line")
                    .child(text().class("campy-choice-tick").child(if chosen {
                        "✓"
                    } else {
                        " "
                    }))
                    .child(text().child(name)),
            )
        };
        card = card.child(row);
    }
    AnyView::new(card)
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

    let rect = signals.rect;
    let enabled = signals.enabled;
    let visible = signals.visible;
    // The shell's own styling hooks: every `class` prop on the description
    // (one per `with_class` call, whitespace-separated within one) lands on
    // the wrapper, beside the `campy-<kind>` class the widget layer uses.
    let classes = desc
        .props
        .iter()
        .filter(|(key, _)| key == "class")
        .filter_map(|(_, value)| value.text().map(str::to_owned))
        .collect::<Vec<_>>()
        .join(" ");
    let mut wrapper = r#box()
        .class("campy-control")
        .class(format!("campy-{}", desc.kind))
        .class(classes)
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

    // A control that carries a hint reports the pointer arriving and leaving, so
    // the loop can put the hint on the status line (the hover half of the old
    // shell's tooltips).
    if let Some(hint) = prop_string(desc, "hint") {
        let enter_host = host.clone();
        let leave_host = host.clone();
        wrapper = wrapper
            .on(events::POINTER_ENTER, move |_| {
                enter_host.emit_raw("hover", hint.clone())
            })
            .on(events::POINTER_LEAVE, move |_| {
                leave_host.emit_raw("hover", "")
            });
    }

    // A control that takes typing says so, so the window's key handler leaves
    // its editing keys alone.
    match desc.kind.as_str() {
        "edit" => {
            let focus_host = host.clone();
            let blur_host = host.clone();
            wrapper = wrapper
                .on(events::FOCUS_IN, move |_| {
                    focus_host.field_focused.set(true)
                })
                .on(events::FOCUS_OUT, move |_| {
                    blur_host.field_focused.set(false)
                });
        }
        "memo" | "code_editor" | "console" => {
            let focus_host = host.clone();
            let blur_host = host.clone();
            wrapper = wrapper
                .on(events::FOCUS_IN, move |_| {
                    focus_host.editor_focused.set(true)
                })
                .on(events::FOCUS_OUT, move |_| {
                    blur_host.editor_focused.set(false)
                });
        }
        _ => {}
    }

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
                // form model). Payload: `x;y;button;mods` — button is
                // left/right/middle on presses and releases, none on
                // moves; mods is a `+`-joined modifier list (none when
                // empty). Positions are window CSS pixels.
                let down_host = host.clone();
                let move_host = host.clone();
                let up_host = host.clone();
                let wheel_host = host.clone();
                let surface_id = desc.id;
                wrapper = wrapper
                    .on(events::POINTER_DOWN, move |cx| {
                        let position: Point<CssPx, Css> = cx.position;
                        let event: &zgui::vocab::PointerEvent = cx;
                        let button = event.button;
                        if pointer_log() {
                            eprintln!(
                                "pointer down at {:.0},{:.0} button {:?}",
                                position.x.0, position.y.0, button
                            );
                        }
                        down_host.emit_raw(
                            &format!("pointer:{surface_id}:down"),
                            pointer_payload(position, button, cx.modifiers),
                        );
                    })
                    .on(events::POINTER_MOVE, move |cx| {
                        let position: Point<CssPx, Css> = cx.position;
                        if pointer_log() {
                            eprintln!("pointer at {:.0},{:.0}", position.x.0, position.y.0);
                        }
                        move_host.emit_raw(
                            &format!("pointer:{surface_id}:move"),
                            pointer_payload(position, None, cx.modifiers),
                        );
                    })
                    .on(events::POINTER_UP, move |cx| {
                        let position: Point<CssPx, Css> = cx.position;
                        let event: &zgui::vocab::PointerEvent = cx;
                        let button = event.button;
                        up_host.emit_raw(
                            &format!("pointer:{surface_id}:up"),
                            pointer_payload(position, button, cx.modifiers),
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
                    // The graph paper under the form: drawn rather than styled,
                    // because a background rule cannot repeat a gradient image.
                    // The brush is the element's own text colour at low alpha,
                    // so it follows the theme without a second token.
                    .child(
                        zgui::elements::canvas()
                            .class("campy-surface-grid")
                            .draw(|cx| {
                                use zgui::canvas::{Brush, ShapeBuilder};
                                let width = cx.size.width.0 as f64;
                                let height = cx.size.height.0 as f64;
                                if width <= 0.0 || height <= 0.0 {
                                    return;
                                }
                                let step = 8.0;
                                let mut path = kurbo::BezPath::new();
                                let mut x = 0.0;
                                while x <= width {
                                    path.move_to((x, 0.0));
                                    path.line_to((x, height));
                                    x += step;
                                }
                                let mut y = 0.0;
                                while y <= height {
                                    path.move_to((0.0, y));
                                    path.line_to((width, y));
                                    y += step;
                                }
                                let hairline = f64::from(cx.scale).max(1.0);
                                cx.scene.push(
                                    ShapeBuilder::new(path)
                                        .stroke(Brush::Inherited { alpha: 0.09 }, hairline)
                                        .build(),
                                );
                            }),
                    );
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

/// The combos a one-line property field owns: they move the caret or select
/// its text. Undo and the clipboard are not among them.
fn caret_combo(combo: &str) -> bool {
    matches!(
        combo,
        "delete" | "backspace" | "left" | "right" | "up" | "down" | "home" | "end" | "ctrl+a"
    )
}

/// The combos a focused editor or terminal owns: the whole editing set, since
/// it has an undo stack and a clipboard of its own.
fn editing_combo(combo: &str) -> bool {
    matches!(
        combo,
        "ctrl+c"
            | "ctrl+x"
            | "ctrl+v"
            | "ctrl+z"
            | "ctrl+y"
            | "ctrl+shift+z"
            | "ctrl+a"
            | "delete"
            | "backspace"
            | "left"
            | "right"
            | "up"
            | "down"
            | "home"
            | "end"
    )
}

/// Whether pointer phases are logged (`CAMPY_POINTER_LOG`), read once.
fn pointer_log() -> bool {
    static ON: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *ON.get_or_init(|| std::env::var_os("CAMPY_POINTER_LOG").is_some())
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
    let text = signals.text;
    match desc.kind.as_str() {
        "label" => AnyView::new(text_element(move || text.get())),

        // A campy-styled base control rather than zgui-ui's Button: the
        // base element is the path verified end to end through real
        // surface input; zgui-ui components get their own live-window A/B
        // in Z2.2 (their own tests dispatch through the component testkit,
        // not the platform).
        "button" => AnyView::new(
            zgui::elements::control()
                .class("campy-widget-button")
                .tabindex(Focus::Sequential)
                .on(events::CLICK, move |_| host.emit(id, "clicked", ""))
                .child(move || text.get()),
        ),

        // A menu shows its `model` as a popup rather than emitting `clicked`:
        // the loop routes `control:<id>:selected` with the item label, which is
        // how File/Edit/Settings reach the actions the old shell had.
        "menu" => {
            let open = host.clone();
            let is_open = host.clone();
            AnyView::new(
                zgui::elements::control()
                    .class("campy-widget-button")
                    .class("campy-menu-trigger")
                    .class_toggle(ClassName::new("campy-menu-on"), move || {
                        let _version = is_open.popup_version();
                        is_open.popup.get() == Some(id)
                    })
                    .tabindex(Focus::Sequential)
                    .on(events::CLICK, move |_| open.toggle_popup(id))
                    .child(move || text.get()),
            )
        }

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
            let checked = signals.checked;
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
            // A field that drops its choices down. zgui-ui's `Select` writes its
            // value back on mount, which fed the loop a new generation every
            // tick, so the popup is the same base-element one the menu bar uses:
            // a row emits `selected` with the option text and a press outside
            // closes it.
            let open = host.clone();
            let value = text;
            AnyView::new(
                zgui::elements::control()
                    .class("campy-widget-button")
                    .class("campy-choice")
                    .tabindex(Focus::Sequential)
                    .on(events::CLICK, move |_| open.toggle_popup(id))
                    .child(
                        r#box()
                            .class("campy-choice-line")
                            .child(crate::controls::text_element(move || value.get()))
                            .child(
                                crate::controls::text_element(|| "▾".to_owned())
                                    .class("campy-choice-mark"),
                            ),
                    ),
            )
        }

        "list" => {
            let model = signals.model;
            let list_host = host.clone();
            AnyView::new(view! {
                VirtualList(
                    count = Signal::derive_local(move || model.get().len()),
                    row_size = 24.0,
                    row = move |index: usize| {
                        let items = model.get();
                        let label = item_text(&items, index);
                        let active = item_active(&items, index);
                        let row_host = list_host.clone();
                        let click_label = label.clone();
                        zgui::elements::control()
                            .class("campy-list-row")
                            .class_toggle(ClassName::new("campy-list-active"), move || active)
                            .tabindex(Focus::Sequential)
                            .on(
                                events::CLICK,
                                move |_| {
                                    let label = click_label.clone();
                                    row_host.emit(id, "selected", label)
                                },
                            )
                            .child(label)
                    },
                )
            })
        }

        "slider" => {
            let value = signals.value;
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
            let progress = signals.progress;
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
                        if let EditorEvent::Edited { .. } = event
                            && let Some(handle) = handle_slot.borrow().as_ref() {
                                event_host.emit_raw(
                                    &format!("editor:{id}:changed"),
                                    handle.query(|snapshot| snapshot.rope().to_string()),
                                );
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

/// The paint a mark class draws with (theme-independent diagnostic colors;
/// the sheet's palette cannot reach editor decorations, so these mirror
/// the standard shadcn diagnostic hues).
fn mark_paint(class: &str) -> &'static str {
    match class {
        "error" => "#ef4444",
        "warning" => "#f59e0b",
        "info" => "#3b82f6",
        "hint" => "#64748b",
        "search" => "#fde047",
        _ => "#94a3b8",
    }
}

/// Applies a marks layer to an editor: squiggle underlines per span, the
/// conventional diagnostics look. An empty layer clears it.
pub fn set_editor_marks(handle: &EditorHandle, layer: &str, items: &[(u64, u64, String)]) {
    if items.is_empty() {
        handle.clear_decorations(layer);
        return;
    }
    let decorations = items
        .iter()
        .map(|(start, end, class)| {
            Decoration::underline(
                *start as usize..*end as usize,
                UnderlineStyle::Squiggly,
                mark_paint(class),
            )
        })
        .collect();
    handle.set_decorations(layer, decorations);
}

/// The keyboard combos the BEAM sees: `key` events with payloads like
/// `ctrl+s`, `shift+ctrl+z`, `f6`, `delete`. Plain typing stays with the
/// focused editor; only modified or special keys cross the bridge (the
/// shell's global bindings live on these, like the old shell's root
/// FocusScope).
fn key_combo(key: &Key, modifiers: Modifiers) -> Option<String> {
    let locks = Modifiers::LOCKS.bits();
    let bits = modifiers.bits() & !locks;
    let mut combo = String::new();
    if bits & Modifiers::CONTROL.bits() != 0 {
        combo.push_str("ctrl+");
    }
    if bits & Modifiers::SHIFT.bits() != 0 {
        combo.push_str("shift+");
    }
    if bits & Modifiers::ALT.bits() != 0 {
        combo.push_str("alt+");
    }
    if bits & Modifiers::META.bits() != 0 {
        combo.push_str("meta+");
    }
    match key {
        Key::Named(named) => {
            let name = named.as_str().to_ascii_lowercase();
            if bits == 0 && !forwardable_named(&name) {
                return None;
            }
            combo.push_str(&name);
        }
        Key::Character(text) => {
            if bits == 0 {
                return None;
            }
            combo.push_str(&text.to_lowercase());
        }
        _ => return None,
    }
    Some(combo)
}

fn forwardable_named(name: &str) -> bool {
    matches!(
        name,
        "enter"
            | "escape"
            | "delete"
            | "backspace"
            | "tab"
            | "home"
            | "end"
            | "pageup"
            | "pagedown"
            | "arrowup"
            | "arrowdown"
            | "arrowleft"
            | "arrowright"
    ) || (name.len() <= 3 && name.starts_with('f') && name[1..].chars().all(|c| c.is_ascii_digit()))
}

/// The pointer payload: `x;y;button;mods` (gaps 4 and 5: the designer's
/// right-click context menu and modifier-gestures ride the extra fields;
/// `x;y` alone remains valid for older parsers).
fn pointer_payload(
    position: Point<CssPx, Css>,
    button: Option<zgui::vocab::PointerButton>,
    modifiers: zgui::vocab::Modifiers,
) -> String {
    let button = button
        .map(|button| match button {
            zgui::vocab::PointerButton::Secondary => "right",
            zgui::vocab::PointerButton::Middle => "middle",
            _ => "left",
        })
        .unwrap_or("none");
    let mut mods = String::new();
    if modifiers.control() {
        mods.push_str("ctrl+");
    }
    if modifiers.shift() {
        mods.push_str("shift+");
    }
    if modifiers.alt() {
        mods.push_str("alt+");
    }
    let mods = mods.trim_end_matches('+');
    format!("{};{};{button};{mods}", position.x.0, position.y.0)
}

#[cfg(test)]
mod tests {
    use super::{is_separator, split_shortcut};

    #[test]
    fn a_menu_label_splits_from_its_shortcut() {
        // The model carries the old shell's item titles verbatim.
        assert_eq!(
            split_shortcut("Save    Ctrl+S"),
            ("Save".to_owned(), "Ctrl+S".to_owned())
        );
        assert_eq!(
            split_shortcut("Save As    Ctrl+Shift+S"),
            ("Save As".to_owned(), "Ctrl+Shift+S".to_owned())
        );
        // One space is part of the name: "Bring to front" has no shortcut.
        assert_eq!(
            split_shortcut("Bring to front"),
            ("Bring to front".to_owned(), String::new())
        );
    }

    #[test]
    fn a_separator_is_an_em_dash_or_nothing() {
        assert!(is_separator("—"));
        assert!(is_separator(""));
        assert!(is_separator("   "));
        assert!(!is_separator("Quit    Ctrl+Q"));
    }
}
