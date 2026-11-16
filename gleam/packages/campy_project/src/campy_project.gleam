//// Project and module documents (ADR 0005).
////
//// A project is a directory:
////
////     campy.json                  schema, title, module order
////     modules/<slug>/form.json    the view document
////     modules/<slug>/handlers.gleam
////
//// `campy.json` and `form.json` are canonical text; handler source is written
//// verbatim. Unknown project fields are preserved, so a newer writer cannot be
//// destroyed by an older reader.

import campy_view.{type Document}
import campy_view/codec.{type Json, JArray, JInt, JObject, JString}
import gleam/dict
import gleam/int
import gleam/list
import gleam/result
import gleam/string

@external(erlang, "campy_project_ffi", "read_file")
fn read_file(path: String) -> Result(String, String)

@external(erlang, "campy_project_ffi", "write_file")
fn write_file(path: String, contents: String) -> Result(Nil, String)

@external(erlang, "campy_project_ffi", "make_dir")
fn make_dir(path: String) -> Result(Nil, String)

pub type Module {
  Module(slug: String, form: Document, handlers: String)
}

pub type Project {
  Project(title: String, modules: List(Module), extra: List(#(String, Json)))
}

pub const schema = 1

pub const project_file = "campy.json"

pub const form_file = "form.json"

pub const handlers_file = "handlers.gleam"

pub fn load(dir: String) -> Result(Project, String) {
  use text <- result.try(read_file(join(dir, project_file)))
  use json <- result.try(codec.parse_json(text))
  use #(title, slugs, extra) <- result.try(parse_manifest(json))
  use _ <- result.try(check_slugs(slugs))
  use modules <- result.try(
    list.try_map(slugs, fn(slug) { load_module(dir, slug) }),
  )

  Ok(Project(title: title, modules: modules, extra: extra))
}

pub fn save(project: Project, dir: String) -> Result(Nil, String) {
  use _ <- result.try(validate(project))
  use _ <- result.try(make_dir(dir))
  use _ <- result.try(write_file(
    join(dir, project_file),
    codec.write_json(manifest(project)),
  ))

  list.try_each(project.modules, fn(module) {
    let module_dir = join(join(dir, "modules"), module.slug)
    use _ <- result.try(make_dir(module_dir))
    use _ <- result.try(write_file(
      join(module_dir, form_file),
      codec.encode_document(module.form),
    ))
    write_file(join(module_dir, handlers_file), module.handlers)
  })
}

pub fn module(project: Project, slug: String) -> Result(Module, String) {
  case list.find(project.modules, fn(module) { module.slug == slug }) {
    Ok(module) -> Ok(module)
    Error(Nil) -> Error("no such module: " <> slug)
  }
}

/// `<control_name>_<event_key>`, the ABI v2 handler name.
pub fn handler_name(control_name: String, event_key: String) -> String {
  control_name <> "_" <> event_key
}

pub fn validate(project: Project) -> Result(Nil, String) {
  let slugs = list.map(project.modules, fn(module) { module.slug })
  use _ <- result.try(check_slugs(slugs))
  case first_duplicate(slugs) {
    Ok(slug) -> Error("duplicate module slug: " <> slug)
    Error(Nil) -> Ok(Nil)
  }
}

fn check_slugs(slugs: List(String)) -> Result(Nil, String) {
  case list.find(slugs, fn(slug) { !is_slug(slug) }) {
    Ok(slug) -> Error("invalid module slug: " <> slug)
    Error(Nil) -> Ok(Nil)
  }
}

fn is_slug(slug: String) -> Bool {
  case slug {
    "" -> False
    _ ->
      slug
      |> string.to_utf_codepoints
      |> list.all(fn(codepoint) {
        let code = string.utf_codepoint_to_int(codepoint)
        code == 95 || code >= 97 && code <= 122 || code >= 48 && code <= 57
      })
  }
}

fn load_module(dir: String, slug: String) -> Result(Module, String) {
  let module_dir = join(join(dir, "modules"), slug)
  use text <- result.try(read_file(join(module_dir, form_file)))
  use document <- result.try(codec.decode_document(text))

  use _ <- result.try(case document.view.kind {
    "form" | "window" -> Ok(Nil)
    other ->
      Error(
        join(module_dir, form_file)
        <> ": root kind must be \"form\", found \""
        <> other
        <> "\"",
      )
  })

  let handlers = case read_file(join(module_dir, handlers_file)) {
    Ok(text) -> text
    Error(_) -> ""
  }

  Ok(Module(slug: slug, form: document, handlers: handlers))
}

fn manifest(project: Project) -> Json {
  let extra =
    project.extra
    |> list.filter(fn(field) {
      !list.contains(["schema", "title", "modules"], field.0)
    })
    |> dict.from_list
    |> dict.to_list
    |> list.sort(by: fn(a, b) { string.compare(a.0, b.0) })

  JObject(list.append(
    [
      #("schema", JInt(schema)),
      #("title", JString(project.title)),
      #(
        "modules",
        JArray(list.map(project.modules, fn(module) { JString(module.slug) })),
      ),
    ],
    extra,
  ))
}

fn parse_manifest(
  json: Json,
) -> Result(#(String, List(String), List(#(String, Json))), String) {
  case json {
    JObject(fields) -> {
      use version <- result.try(require_int(fields, "schema", "$"))
      case version == schema {
        False -> Error("unsupported project schema: " <> int.to_string(version))
        True -> {
          use title <- result.try(require_string(fields, "title", "$"))
          use slugs <- result.try(require_strings(fields, "modules", "$"))
          let extra =
            fields
            |> list.filter(fn(field) {
              !list.contains(["schema", "title", "modules"], field.0)
            })
            |> list.sort(by: fn(a, b) { string.compare(a.0, b.0) })
          Ok(#(title, slugs, extra))
        }
      }
    }
    _ -> Error("$: expected an object")
  }
}

fn require_field(
  fields: List(#(String, Json)),
  name: String,
  path: String,
) -> Result(Json, String) {
  case list.find(fields, fn(field) { field.0 == name }) {
    Ok(#(_, value)) -> Ok(value)
    Error(Nil) -> Error(path <> ": missing \"" <> name <> "\"")
  }
}

fn require_int(
  fields: List(#(String, Json)),
  name: String,
  path: String,
) -> Result(Int, String) {
  use value <- result.try(require_field(fields, name, path))
  case value {
    JInt(number) -> Ok(number)
    _ -> Error(path <> "." <> name <> ": expected an integer")
  }
}

fn require_string(
  fields: List(#(String, Json)),
  name: String,
  path: String,
) -> Result(String, String) {
  use value <- result.try(require_field(fields, name, path))
  case value {
    JString(text) -> Ok(text)
    _ -> Error(path <> "." <> name <> ": expected a string")
  }
}

fn require_strings(
  fields: List(#(String, Json)),
  name: String,
  path: String,
) -> Result(List(String), String) {
  use value <- result.try(require_field(fields, name, path))
  case value {
    JArray(items) ->
      items
      |> list.index_map(fn(item, index) {
        case item {
          JString(text) -> Ok(text)
          _ ->
            Error(
              path
              <> "."
              <> name
              <> "["
              <> int.to_string(index)
              <> "]: expected a string",
            )
        }
      })
      |> result.all
    _ -> Error(path <> "." <> name <> ": expected an array of strings")
  }
}

fn first_duplicate(items: List(String)) -> Result(String, Nil) {
  first_duplicate_loop(items, dict.new())
}

fn first_duplicate_loop(
  items: List(String),
  seen: dict.Dict(String, Nil),
) -> Result(String, Nil) {
  case items {
    [] -> Error(Nil)
    [first, ..rest] ->
      case dict.has_key(seen, first) {
        True -> Ok(first)
        False -> first_duplicate_loop(rest, dict.insert(seen, first, Nil))
      }
  }
}

fn join(left: String, right: String) -> String {
  case string.ends_with(left, "/") {
    True -> left <> right
    False -> left <> "/" <> right
  }
}
