# Component API

## Implemented bootstrap contract

`campy_ui.Definition` contains a component ID, title, and data-only visual tree.
The first tree supports `Row`, `TextField`, and `Button`. Typed text bindings are
literal strings or the `Query` property. Typed boolean bindings are literals,
`Busy`, or `Not`. Node IDs are validated before generating source.

The current emitted window interface is fixed:

```text
query: String             editable model property
busy: Bool                input property
query-changed(String)     user edit event
search()                  button action
```

`campy_search_box.describe()` constructs the tree. Its `Model`, `Event`, `init`,
and `update` are handwritten first-slice examples. `Search` sets `busy`; a completion
event and actual asynchronous effect are M2 work. The native host now logs delivered callback events; full effect wiring is M2.

`campy_bridge.protocol_version()` returns 1. `validate_ui(source)` returns
`Result(Int, String)`, with the exported component count on success. It creates no
window and retains no component handles. The host checks protocol compatibility.

The live bridge now also exposes actor-owned `Session` resources, `open_session`,
`session_id`, `submit`, `close_session`, and mailbox `poll`. Supported commands are
`LoadUi`, `SetText`, `SetBool`, `SetInt`, `SetColor`, `SetModel`, `ReadText`,
`Resize`, and `Snapshot`, tagged with a positive UI generation. `SetModel`
carries a generic value tree (text/bool/int/list/struct/image) converted to Slint
structs and models, so `for` loops and image fields can be driven at runtime
without regenerating the UI source. `SetColor` accepts `#rrggbb` and is used for
live theme colors. Success
from `submit` means enqueued; the owner receives completion or diagnostics
asynchronously. Only the owning actor may issue commands.
The current callback wire format supports the MVP's string or empty payload;
generic generated event codecs remain M1 work.

## Intended M1 API (design sketch, not implemented)

```gleam
pub fn describe() -> component.Definition {
  let query = property.string(id: "p-query", name: "query", default: "")
  let busy = property.bool(id: "p-busy", name: "busy", default: False)
  let changed = event.string(id: "e-changed", name: "query_changed")
  let search = event.unit(id: "e-search", name: "search")

  component.define(
    id: "campy.search-box",
    properties: [property.export(query), property.export(busy)],
    events: [event.export(changed), event.export(search)],
    body: ui.row(id: "root", children: [
      ui.text_field(
        id: "query-input",
        value: binding.read(query),
        on_changed: event.forward(changed),
      ),
      ui.button(
        id: "search-button",
        text: binding.string("Search"),
        enabled: binding.not(binding.read(busy)),
        on_clicked: event.send(search, Nil),
      ),
    ]),
  )
}
```

Typed handles validate expressions during construction; exported descriptors are
uniform serialized schema entries. Generate `Properties`, `Event`, and codecs from
that schema. Generate independent facade modules before compiling their consumers.
Do not maintain the public event type and schema separately after M1.

## Intended behavior contract

```text
init(inputs)              → state + initial effects
update(state, message)    → state + effects
present(state)            → generated properties
migrate(version, snapshot)→ Result(new state, migration error)
```

The stable runtime owns scheduling. Handlers remain on BEAM. Native callbacks carry
instance, UI generation, interface-member identity, payload, and model revision.
Each effect has an ID and cancellation/retirement policy. Invalid payloads fail
decoding at the dynamic boundary rather than entering a typed reducer.

## Package compatibility

A runtime-loadable package declares descriptor format, required bridge protocol,
runtime capabilities, component IDs, dependencies, and state schema versions.
Compatible new components load without rebuilding native code. New rendering or
OS primitives may require a runtime upgrade. The MVP does not promise hot NIF
replacement or arbitrary state-type changes.

## CCL — Campy Component Library

`campy_ccl` is the shared catalog for the designer, the run-window emitter, and
the IDE palette. The basic LCL-inspired set is:

| Key | LCL analogue | Slint rendering | Event |
|---|---|---|---|
| `label` | TLabel | `Text` | — |
| `edit` | TEdit | `LineEdit` | `changed` |
| `memo` | TMemo | `TextEdit` | `changed` |
| `button` | TButton | `Button` | `clicked` |
| `menu` | TMainMenu | menu title + popup items | `selected` |
| `checkbox` | TCheckBox | `CheckBox` | `toggled` |
| `radio` | TRadioButton | custom circle + text | `clicked` |
| `combo` | TComboBox | `ComboBox` | `selected` |
| `list` | TListBox | `ListView` | — |
| `slider` | TTrackBar | `Slider` | `changed` |
| `progress` | TProgressBar | `ProgressIndicator` | — |
| `panel` | TPanel | container `Rectangle` | — |
| `group` | TGroupBox | titled container | — |
| `picture` | TImage | `Image` (`@image-url`) | — |

Where LCL and Slint disagree, Slint's model wins: properties and events follow
the Slint widgets, and layout uses Slint's Free/Column/Row model. LCL-style
Top/Bottom/Left/Right/Client alignment is available on Free-layout controls and
follows the parent container. Panels and group boxes also have a
Free/Column/Row child layout;
docking order and anchors are not reproduced yet. The catalog supplies the
palette labels (icon + LCL-style name), default sizes, default text, child
acceptance, and handler event keys. Handler names remain `<control>_<event>`
(e.g. `save_clicked`, `search_changed`). Numeric progress/slider values live in
the control's text field (0–100).

## Live preview

The running app uses a separate, model-driven Slint shell: a `PreviewControl`
model (`id`, `kind`, `text`, geometry, enabled/visible, image, numeric value),
`title`, `form-w`/`form-h`, `layout-free/column/row`, and a generic
`event(string)` callback carrying `control-id:event`. Run loads the shell once.
F7 re-applies a snapshot (title, size, layout, controls) to the same session;
no `LoadUi` or window recreation is involved. Events are mapped back to the
derived handler names (`<control>_<event>`). The static form emitter is still
used for the read-only generated-Slint tab and visual fixtures.

## MCP tools

When enabled from Settings → Agent, Campy exposes a localhost streamable HTTP
MCP endpoint (`http://127.0.0.1:<port>/mcp`) with these tools:

- `campy_status`, `campy_modules`, `campy_form`, `campy_console`
- `campy_run`, `campy_stop`, `campy_update_app`
- `campy_select_control` (`id`)
- `campy_set_control` (`id`, `field`, `value`)
- `campy_send_input` (`text`)

Tools are executed by the IDE loop; the server is disabled by default and binds
to localhost only. The console's stdin is logged/reserved because the preview
does not yet execute handler code.

## Workspace

A workspace is a versioned compressed Erlang term
(`projects/workspace.campy`, v1) containing full project snapshots plus the
active project path. Campy auto-saves it after document or project-list changes.
Projects can be switched, created (`Project N` with a `Main` module and a unique
`projects/project-N.campy` path), and deleted from the workspace; deleting keeps
the project file. Each project is independently versioned (v6 now) and keeps its
own modules, form, handler source, undo history, and path.

## Designer model (current IDE slice)

`campy_form` provides the IDE's form model (the CCL kinds with absolute
geometry), a form-level `Free | Column | Row` layout, per-container layouts, a
parent map for container adoption, an alignment map, derived handler names and
stub generation, subtree copy/paste, the versioned project codec (v6), the
workspace codec, and the standalone form-window emitter. Panels and the window root
accept children; adoption walks from the selected control to its first accepting
ancestor and falls back to the window. Picture stores its path in the control's
text field and is emitted with `@image-url(...)` in the run window. Free forms
support cursor move and eight-handle resize; Column/Row forms use Slint
layouts. Dropping a control over a panel/group box reparents it; dropping it
outside all containers returns it to the window. Rendering orders a container
before its children so adopted controls stay visible. The designer
model is deliberately separate
from the M1 versioned component schema: the visual designer was built ahead of
M1 to validate the interaction model (palette → canvas → inspector → handler
editor) before committing to generic descriptors. When M1 lands, the designer
model is expected to be re-based on those shared descriptors rather than keeping
two schemas.

