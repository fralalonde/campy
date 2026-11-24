# Code samples: the same campy concerns in Slint, zgui, and Xilem/Masonry

Each sample implements a campy-flavored concern: a reactive counter form,
a hot-reload cycle, and the NIF-thread question. They are the basis for the
impedance-mismatch analysis.

---

## 1. The same form, three ways

**The form**: a label showing a count and a button that increments it — the
canonical designed-component, with the *handler on the BEAM* in campy.

### 1a. Slint today (campy's actual path)

The Gleam designer emits Slint source; the bridge compiles it at runtime and
drives it through a *generic* property/callback API. Nothing per-component
exists in Rust.

```rust
// campy-renderer/src/sessions.rs (condensed to the essential)
fn load(&mut self, generation: u64, source: String) -> Result<(), String> {
    let result = super::compile_source(&source)?;          // interpreter
    let definition = result.component("CampyPreview").unwrap();
    let candidate = definition.create().map_err(|e| e.to_string())?;
    for (name, kind) in definition.properties() { /* copy state from old */ }
    for name in definition.callbacks() {
        candidate.set_callback(&name, move |args| {
            sink(Event { kind: format!("callback:{name}"),
                         payload: args.first().unwrap().to_string(), .. });
            Value::Void
        })?;
    }
    candidate.show()?;
    self.instance.replace(candidate);
    Ok(())
}
```

Pros: UI-as-data, zero Rust per component, hot reload = new string.
Cons: a separate DSL to generate; property access is stringly-typed at the
boundary; the interpreter adds ~45 ms of compile per F6 (measured below).

### 1b. zgui (Rust-first, with an imperative seam for bridges)

The idiomatic zgui component is compiled Rust with a CSS sheet:

```rust
use zgui::prelude::*;

#[component]
fn Counter() -> impl IntoView {
    let count = RwSignal::new(0);
    view! {
        row(class = "counter") {
            text(class = "value") {{move || count.get().to_string()}}
            control(on:click = move |_| count.update(|n| *n += 1)) { "Increment" }
        }
    }
}

const STYLE: &str = css!(
    ".counter { gap: 12px; align-items: center; }
     .value { font-size: 48px; font-weight: 700; }"
);

fn main() -> Result<(), zgui::Error> {
    app().with_title("Counter").with_stylesheet(STYLE).run(|| view! { Counter() })
}
```

For campy the interesting part is the seam underneath: every view, including
`Counter`, is driven through ~10 imperative operations on a `Dom` trait —
and the real implementation over the document is public.

```rust
// zgui-view's Dom seam (verbatim from the docs of the trait):
//   "The operations are deliberately small and deliberately imperative ...
//    it is small enough that a new backend is an afternoon rather than a project."
let row  = dom.create_element(ElementName::new("row"));
let text = dom.create_text("hello");
dom.insert(row, text, None);
dom.set_classes(row, &[ClassName::new("toolbar")]);
dom.set_text(text, "41");
```

A campy port could therefore keep its **Gleam-authored component model** and
translate wire commands to `Dom` operations, with `zgui-view-dom::DocumentDom`
as the implementation — the same architecture as the Slint bridge, minus the
stringly-typed property layer. The `HostBinding` seam ("Event, frame and
shutdown hooks for an embedded script engine"; only a no-op impl ships today)
is where an embedded BEAM would officially plug in.

### 1c. Xilem (Rust views over Masonry widgets)

The idiomatic xilem form is a pure view function over app state:

```rust
// xilem 0.4 (idiomatic): a pure view function over app state
use xilem::view::{flex_col, flex_row, label, text_button};
use xilem::{EventLoop, WindowOptions, Xilem};

fn form(count: &mut u32) -> impl WidgetView<u32> {
    flex_col((
        flex_row((label(format!("Count: {count}")), text_button("Increment", |n: &mut u32| *n += 1))),
    ))
}

fn main() -> Result<(), winit::error::EventLoopError> {
    let app = Xilem::new_simple(0u32, form, WindowOptions::new("Counter"));
    app.run_in(EventLoop::with_user_event())
}
```

Each button press re-runs `form`, the returned view tree is diffed against
the previous one, and the diff is applied to the retained Masonry widgets.

Masonry alone (no xilem) is what a campy bridge would actually target —
retained widgets edited imperatively:

```rust
// masonry: retained widgets, imperative edits, action callbacks
let root = Flex::column()
    .with_child(Label::new("Count: 0").with_id(lbl_id))
    .with_child(Button::new(Label::new("Increment").with_auto_id()).with_id(btn_id));
let mut harness = TestHarness::create(default_property_set(), root);
// ... later, on a property publish:
harness.edit_widget_with_id(lbl_id, |mut w| {
    let mut label = w.downcast::<Label>();
    Label::set_text(&mut label, "Count: 41");
});
```

There is no interpreter and no document seam: the "component language" is
Rust. Driving it from BEAM data means writing and maintaining a
descriptor→widget-tree compiler yourself, and dynamic composition fights the
type system (`Either`, `OneOf`, boxed views) rather than being designed for.

---

## 2. Hot reload

### 2a. Slint — built in (what campy does today)

`F6`: Gleam hot-loads modules, regenerates the Slint shell, then submits a
`LoadUi` with a new generation. The native side compiles the candidate,
copies matching public properties, and only then swaps windows — failed
candidates never replace the running UI. `F7`: publish-only updates
(`SetText`/`SetModel`) re-apply to the live window, no reload at all.
Measured below: ~60 ms for a 64-control F6 (mostly interpreter compile),
~6 ms per F7 property frame.

### 2b. zgui — two cheap reload primitives, no code reload

* **Data reload**: the view closure is `FnMut() -> V` and re-runs whenever a
  window is rebuilt (`Harness::suspend(); Harness::resume();` rebuilds every
  view from current data). Measured below: ~18 ms for the 64-control form.
* **Style reload**: stylesheets install at runtime (`install_stylesheet`,
  used by every zgui-ui component), so theme/restyling hot-swaps without
  touching the document.
* **Code reload**: none. Rust components need a process restart (or an
  external dylib scheme zgui does not provide). Since zgui is a compiled
  framework, a BEAM-driven campy would put *all* reloadable structure in the
  wire data anyway — same as campy does with Slint today.

### 2c. Xilem — you build it all yourself

Xilem has no interpreter, no runtime stylesheet, no view-rebuild entry point
exposed for embedding (`Xilem::run` owns the event loop), and Masonry 0.4 has
no public in-place root replacement — a reload means rebuilding the widget
tree through your own bridge code (measured: sub-millisecond for the passes
alone, but the machinery around it — state capture, focus/scroll/text
preservation — is exactly the part campy already had to write for Slint and
would rewrite here). Hot-reloading Rust itself (hot-lib-reloader/dylib) is
the other route; it was on xilem's 2024 roadmap and was not completed.

---

## 3. The NIF-thread constraint (all three)

Campy runs the UI event loop on a thread spawned by a Rustler NIF; the BEAM
owns the OS main thread. That only works because the windowing backend allows
it:

| Toolkit | Runs its event loop on a NIF-spawned thread? |
|---|---|
| **Slint** | Yes, out of the box on Linux+Windows: the pinned winit backend sets `with_any_thread(true)` (campy ADR 0001). |
| **zgui** | Not out of the box, but designed for it: `zgui-platform-winit::event_loop()` is split from `run()` "so a caller who has to own the loop — a program embedding this in a larger process — can have it". One-line patch adds `with_any_thread(true)`. On Wayland, zgui's *own* compositor backend (`zgui-platform-wayland`) doesn't use winit at all — no main-thread restriction exists there. |
| **Xilem/Masonry** | No: `masonry_winit` builds a plain `EventLoop` (main-thread only) and `run_app`s it. A campy port needs a maintained fork/patch with `with_any_thread(true)` (Linux+Windows only; macOS NIF UI remains impossible for all three). |

---

## 4. WYSIWYG designer implications

The campy designer (`campy_ccl` → `campy_form`) needs a rendering target
whose widget model can be *driven generically* and *hit-tested from geometry*.

| Need | Slint | zgui | Masonry 0.4 |
|---|---|---|---|
| label/edit/memo | Text, LineEdit, TextEdit | text/label, field, editor | Label, TextInput, TextArea |
| button | Button | control + zgui-ui Button | Button |
| checkbox/radio | CheckBox (radio via CheckBox) | zgui-ui Checkbox/radio_group | Checkbox (no radio) |
| combo/list | ComboBox, ListView | zgui-ui Select, VirtualList | — (Grid+VirtualScroll primitives only) |
| menu | Menu/MenuItem, ContextMenuArea | zgui-ui menubar/menu/context_menu | — |
| slider/progress | Slider, ProgressIndicator | zgui-ui Slider, Progress | Slider, ProgressBar |
| tables | (hand-built) | zgui-ui data_table | Grid (manual) |
| hit-testing from geometry | TouchArea + `PointerEvent` with `mouse-x/y` | engine-computed boxes + `box_with_class`, dispatcher | `mouse_move_to(WidgetId)`, widget rects |
| restyle a live form | recompile or per-property SetColor | swap stylesheet at runtime, CSS cascade | per-widget property edits |

zgui's F12 inspector (box model, per-frame cost timeline, element picking)
is the closest thing to a built-in designer tool of the three; the
`FrameProbe` seam is exactly where campy's own designer instrumentation
would attach.
