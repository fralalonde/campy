//// Pure generator: a project module becomes a standalone Gleam app source
//// tree.
////
//// `generate` writes exactly three files — `gleam.toml`, an entry module with a
//// `main`, and the module's handler source verbatim — and nothing else. It does
//// not build, package, or copy assets; that is the broker's job.
////
//// The designed form is embedded as Gleam code (`form()`), so a generated app
//// never reads a project file at runtime. The entry module owns the single
//// `campy_bridge.poll` loop of its own VM and forwards events to `campy_app`,
//// which derives the live-preview snapshot and dispatches ABI v1 handlers from
//// the form. Handler names are never generated as call sites: the emitted
//// `handlers_module` constant plus dynamic dispatch keeps every existing
//// handler source valid unchanged.
////
//// Generated console lines go through `campy_app.report_line`, so the
//// `[<app>] <variant>` format stays defined in one place.
////
//// ## Output location
////
//// Dependency paths in the emitted `gleam.toml` assume `out_dir` is
//// `<repo-root>/generated/apps/<module_slug>` — the broker's P1 build
//// location (T1.3) — where `../../../` reaches the repository root. A tree
//// generated elsewhere needs its own path deps.

import campy_ccl
import campy_form
import campy_form/project as project_codec
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string

@external(erlang, "campy_appgen_ffi", "ascii_fold")
fn ascii_fold(text: String) -> String

@external(erlang, "campy_appgen_ffi", "write_file")
fn write_file(path: String, contents: String) -> Result(Nil, String)

// Lowercase ASCII slug for an app name. Unicode letters are folded first, so
// accented letters keep their base letter ("Cat Café" -> "cat_cafe"); every
// other character becomes a separator, repeats collapse, and the result can
// never be empty or start with a digit.
pub fn slug(name: String) -> String {
  let folded = ascii_fold(name) |> string.lowercase
  let cleaned =
    folded
    |> string.to_graphemes
    |> list.fold([], fn(characters, character) {
      case kept_character(character) && character != "_" {
        True -> [character, ..characters]
        False ->
          case characters {
            ["_", ..] -> characters
            _ -> ["_", ..characters]
          }
      }
    })
    |> list.reverse
    |> string.concat
    |> trim_underscores
  case cleaned {
    "" -> "a"
    _ ->
      case starts_with_digit(cleaned) {
        True -> "a" <> cleaned
        False -> cleaned
      }
  }
}

// Write the standalone app tree for one project module into `out_dir`,
// creating directories as needed. `Ok` carries the output directory. An
// unknown module id is an error; nothing is written in that case. An external
// module owns its source in a file on disk, which the pure generator does not
// read, so generation is an explicit error for it. Emitted dependency paths
// assume `out_dir` is `<repo-root>/generated/apps/<slug>` (the broker's build
// location), so `../../../` reaches the repo root.
pub fn generate(
  project: project_codec.Project,
  module_id: String,
  out_dir: String,
) -> Result(String, String) {
  case project_codec.find_module(project, module_id) {
    None -> Error("unknown module: " <> module_id)
    Some(module) -> {
      case module.source_origin {
        project_codec.Embedded(source) -> {
          let module_slug = slug(module.name)
          let entry_module = "campy_app_" <> module_slug
          let handlers_module = "handlers_" <> module_slug
          let files = [
            #(out_dir <> "/gleam.toml", gleam_toml(module_slug)),
            #(
              out_dir <> "/src/" <> entry_module <> ".gleam",
              entry_source(module_slug, module),
            ),
            #(out_dir <> "/src/" <> handlers_module <> ".gleam", source),
          ]
          case write_files(files) {
            Ok(Nil) -> Ok(out_dir)
            Error(error) -> Error(error)
          }
        }
        project_codec.External(path) ->
          Error("module " <> module_id <> " has an external source: " <> path)
      }
    }
  }
}

fn write_files(files: List(#(String, String))) -> Result(Nil, String) {
  case files {
    [] -> Ok(Nil)
    [#(path, contents), ..rest] ->
      case write_file(path, contents) {
        Ok(Nil) -> write_files(rest)
        Error(error) -> Error(error)
      }
  }
}

fn kept_character(character: String) -> Bool {
  string.contains("abcdefghijklmnopqrstuvwxyz0123456789_", character)
}

fn starts_with_digit(text: String) -> Bool {
  case string.first(text) {
    Ok(character) -> string.contains("0123456789", character)
    Error(_) -> False
  }
}

fn trim_underscores(text: String) -> String {
  text
  |> drop_leading_underscores
  |> drop_trailing_underscores
}

fn drop_leading_underscores(text: String) -> String {
  case string.starts_with(text, "_") {
    True -> drop_leading_underscores(string.drop_start(text, 1))
    False -> text
  }
}

fn drop_trailing_underscores(text: String) -> String {
  case string.ends_with(text, "_") {
    True -> drop_trailing_underscores(string.drop_end(text, 1))
    False -> text
  }
}

fn gleam_toml(module_slug: String) -> String {
  [
    "name = \"campy_app_" <> module_slug <> "\"",
    "version = \"0.1.0\"",
    "target = \"erlang\"",
    "gleam = \">= 1.16.0 and < 2.0.0\"",
    "",
    "[dependencies]",
    "gleam_stdlib = \">= 0.70.0 and < 1.0.0\"",
    "campy_app = { path = \"../../../gleam/packages/campy_app\" }",
    "campy_bridge = { path = \"../../../gleam/packages/campy_bridge\" }",
    "campy_form = { path = \"../../../gleam/packages/campy_form\" }",
    "campy_runtime = { path = \"../../../gleam/packages/campy_runtime\" }",
    "",
    "[dev-dependencies]",
    "gleeunit = \">= 1.0.0 and < 2.0.0\"",
    "",
  ]
  |> string.join("\n")
}

fn entry_source(module_slug: String, module: project_codec.Module) -> String {
  list.flatten([
    [
      "//// Standalone Campy app for the " <> quote(module.name) <> " module.",
      "////",
      "//// Generated by campy_appgen; edit the module in Campy, not this file.",
      "//// The app owns the single `campy_bridge.poll` loop of its own VM and",
      "//// forwards every event to `campy_app`.",
    ],
    handler_comment_lines(module.form),
    [
      "",
      "import campy_app",
      "import campy_bridge",
      "import campy_form",
      "import gleam/io",
      "import gleam/option.{None, Some}",
      "",
      "pub const app = " <> quote(module_slug),
      "",
      "// The artifact manifest carries the real version and digest; a standalone",
      "// source tree starts at the first version.",
      "pub const app_version = 1",
      "",
      "pub const app_digest = \"\"",
      "",
      "pub const handlers_module = " <> quote("handlers_" <> module_slug),
    ],
    form_lines(module.form),
    [
      "",
      "pub fn main() {",
      "  let config =",
      "    campy_app.default_config(",
      "      app: app,",
      "      version: app_version,",
      "      digest: app_digest,",
      "      handlers_module: handlers_module,",
      "      form: form(),",
      "      report: report,",
      "    )",
      "  case campy_app.start(config) {",
      "    Ok(ref) -> poll_loop(ref)",
      "    Error(error) ->",
      "      io.println_error(campy_app.report_line(app, campy_app.Console(error)))",
      "  }",
      "}",
      "",
      "fn report(report: campy_app.Report) -> Nil {",
      "  io.println(campy_app.report_line(app, report))",
      "}",
      "",
      "fn poll_loop(ref: campy_app.Ref) -> Nil {",
      "  case campy_bridge.poll(100) {",
      "    Some(event) -> {",
      "      campy_app.deliver(ref, event)",
      "      poll_loop(ref)",
      "    }",
      "    None -> poll_loop(ref)",
      "  }",
      "}",
    ],
  ])
  |> string.join("\n")
  |> fn(source) { source <> "\n" }
}

// The ABI v1 dispatch surface, derived from the form and the CCL catalog. It is
// documentation only: campy_app resolves the same names from the form at
// runtime, so no call sites are generated.
fn handler_comment_lines(form: campy_form.Form) -> List(String) {
  let entries =
    list.flat_map(form.controls, fn(control) {
      campy_ccl.events(campy_form.kind_key(control.kind))
      |> list.map(fn(event) {
        let name = campy_form.handler_name(control, event.key)
        "////   " <> control.id <> " " <> event.key <> " -> " <> name
      })
    })
  case entries {
    [] -> ["////", "//// This design declares no handler events."]
    _ ->
      list.append(
        ["////", "//// Handlers (ABI v1; resolved from the form at runtime):"],
        entries,
      )
  }
}

fn form_lines(form: campy_form.Form) -> List(String) {
  list.flatten([
    ["", "pub fn form() -> campy_form.Form {", "  campy_form.Form("],
    [
      "    " <> quote(form.id) <> ",",
      "    " <> quote(form.title) <> ",",
      "    " <> int.to_string(form.width) <> ",",
      "    " <> int.to_string(form.height) <> ",",
      "    campy_form." <> layout_name(form.layout) <> ",",
    ],
    list_argument("    ", list.map(form.controls, control_block)),
    list_argument(
      "    ",
      list.map(form.parents, fn(entry) {
        [pair_source(quote(entry.0), quote(entry.1))]
      }),
    ),
    list_argument(
      "    ",
      list.map(form.aligns, fn(entry) {
        [pair_source(quote(entry.0), "campy_form." <> align_name(entry.1))]
      }),
    ),
    list_argument(
      "    ",
      list.map(form.layouts, fn(entry) {
        [pair_source(quote(entry.0), "campy_form." <> layout_name(entry.1))]
      }),
    ),
    list_argument(
      "    ",
      list.map(form.borders, fn(entry) {
        [pair_source(quote(entry.0), int.to_string(entry.1))]
      }),
    ),
    list_argument(
      "    ",
      list.map(form.transparencies, fn(entry) {
        [pair_source(quote(entry.0), int.to_string(entry.1))]
      }),
    ),
    list_argument(
      "    ",
      list.map(form.colors, fn(entry) {
        [pair_source(quote(entry.0), quote(entry.1))]
      }),
    ),
    ["  )", "}"],
  ])
}

fn control_block(control: campy_form.Control) -> List(String) {
  list.flatten([
    [
      "campy_form.Control(",
      "  " <> quote(control.id) <> ",",
      "  " <> quote(control.name) <> ",",
      "  campy_form." <> kind_name(control.kind) <> ",",
      "  " <> int.to_string(control.x) <> ",",
      "  " <> int.to_string(control.y) <> ",",
      "  " <> int.to_string(control.width) <> ",",
      "  " <> int.to_string(control.height) <> ",",
      "  " <> quote(control.text) <> ",",
      "  " <> bool_source(control.enabled) <> ",",
      "  " <> bool_source(control.visible) <> ",",
    ],
    list_argument(
      "  ",
      list.map(control.props, fn(entry) {
        [pair_source(quote(entry.0), quote(entry.1))]
      }),
    ),
    [")"],
  ])
}

fn pair_source(first: String, second: String) -> String {
  "#(" <> first <> ", " <> second <> ")"
}

// Render one list argument in the formatter's canonical block shape. Item
// blocks are already relative to the list's contents; each gets a trailing
// comma, and the list itself ends in `],`.
fn list_argument(indent: String, items: List(List(String))) -> List(String) {
  case items {
    [] -> [indent <> "[],"]
    _ ->
      list.flatten([
        [indent <> "["],
        list.flatten(
          list.map(items, fn(block) {
            block
            |> append_comma
            |> list.map(fn(line) { indent <> "  " <> line })
          }),
        ),
        [indent <> "],"],
      ])
  }
}

fn append_comma(lines: List(String)) -> List(String) {
  case list.reverse(lines) {
    [] -> []
    [last, ..rest] -> list.reverse([last <> ",", ..rest])
  }
}

fn quote(text: String) -> String {
  "\""
  <> string.concat(list.map(string.to_graphemes(text), escape_character))
  <> "\""
}

fn escape_character(character: String) -> String {
  case character {
    "\\" -> "\\\\"
    "\"" -> "\\\""
    "\n" -> "\\n"
    "\r" -> "\\r"
    "\t" -> "\\t"
    other -> other
  }
}

fn bool_source(value: Bool) -> String {
  case value {
    True -> "True"
    False -> "False"
  }
}

fn layout_name(layout: campy_form.Layout) -> String {
  case layout {
    campy_form.Free -> "Free"
    campy_form.Column -> "Column"
    campy_form.Row -> "Row"
  }
}

fn align_name(align: campy_form.Align) -> String {
  case align {
    campy_form.NoAlign -> "NoAlign"
    campy_form.Top -> "Top"
    campy_form.Bottom -> "Bottom"
    campy_form.Left -> "Left"
    campy_form.Right -> "Right"
    campy_form.Client -> "Client"
    campy_form.Fill -> "Fill"
  }
}

fn kind_name(kind: campy_form.Kind) -> String {
  case kind {
    campy_form.Label -> "Label"
    campy_form.EditBox -> "EditBox"
    campy_form.Memo -> "Memo"
    campy_form.Button -> "Button"
    campy_form.CheckBox -> "CheckBox"
    campy_form.RadioButton -> "RadioButton"
    campy_form.ComboBox -> "ComboBox"
    campy_form.ListBox -> "ListBox"
    campy_form.Slider -> "Slider"
    campy_form.Progress -> "Progress"
    campy_form.Panel -> "Panel"
    campy_form.GroupBox -> "GroupBox"
    campy_form.Picture -> "Picture"
    campy_form.Menu -> "Menu"
  }
}
