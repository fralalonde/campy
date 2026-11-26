//// The non-visual components a form declares, and what a running app does
//// with them.
////
//// A `timer` ticks at its interval and advances the control named by its
//// `target` (a progress bar's value, or a label's elapsed seconds). A
//// `datasource` reads its URL (http(s) or a file path) and fills the list
//// named by its `target`. The host that runs them is the IDE's preview loop;
//// a generated app declares the same components to its own host.
////
//// The component's own event (`tick`, `loaded`, `failed`) is what a module's
//// handler would answer; the preview reports it on the console.

import campy_form
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// A timer's declared behaviour. `wire` is the component's id in the running
/// window, `interval` its period in milliseconds.
pub type Timer {
  Timer(
    wire: Int,
    name: String,
    interval: Int,
    target: String,
    step: Int,
    maximum: Int,
  )
}

/// A datasource's declared behaviour.
pub type Datasource {
  Datasource(wire: Int, name: String, url: String, target: String)
}

pub fn timers(form: campy_form.Form) -> List(Timer) {
  form.controls
  |> list.filter(fn(control) { control.kind == campy_form.Timer })
  |> list.filter_map(fn(control) {
    case control.enabled {
      False -> Error(Nil)
      True -> {
        let interval = number(control, "interval", 1000)
        case interval > 0 {
          False -> Error(Nil)
          True ->
            Ok(Timer(
              campy_form.control_wire_id(control),
              control.name,
              interval,
              campy_form.control_prop(control, "target", ""),
              number(control, "step", 1),
              number(control, "maximum", 100),
            ))
        }
      }
    }
  })
}

pub fn datasources(form: campy_form.Form) -> List(Datasource) {
  form.controls
  |> list.filter(fn(control) { control.kind == campy_form.Datasource })
  |> list.filter_map(fn(control) {
    let url = string.trim(campy_form.control_prop(control, "url", ""))
    case control.enabled, url {
      True, "" -> Error(Nil)
      True, url ->
        Ok(Datasource(
          campy_form.control_wire_id(control),
          control.name,
          url,
          campy_form.control_prop(control, "target", ""),
        ))
      False, _ -> Error(Nil)
    }
  })
}

fn number(control: campy_form.Control, key: String, fallback: Int) -> Int {
  case int.parse(string.trim(campy_form.control_prop(control, key, ""))) {
    Ok(value) -> value
    Error(_) -> fallback
  }
}

/// The strings of a JSON array (`["a", "b"]`), or the non-empty lines of plain
/// text. Enough for a datasource that fills a list, and no JSON parser in the
/// IDE for everything else.
pub fn entries(body: String) -> List(String) {
  case string.trim(body) |> string.starts_with("[") {
    True -> json_strings(body, [])
    False ->
      body
      |> string.split("\n")
      |> list.map(string.trim)
      |> list.filter(fn(line) { line != "" })
  }
}

fn json_strings(text: String, acc: List(String)) -> List(String) {
  case string.split_once(text, "\"") {
    Error(_) -> list.reverse(acc)
    Ok(#(_, rest)) -> {
      let #(value, rest) = take_string(rest, "")
      json_strings(rest, [value, ..acc])
    }
  }
}

fn take_string(text: String, acc: String) -> #(String, String) {
  let assert [first, ..rest] = string.to_graphemes(text)
  case first {
    "\"" -> #(acc, string.concat(rest))
    "\\" ->
      case rest {
        ["n", ..rest] -> take_string(string.concat(rest), acc <> "\n")
        ["t", ..rest] -> take_string(string.concat(rest), acc <> "\t")
        [escaped, ..rest] -> take_string(string.concat(rest), acc <> escaped)
        [] -> #(acc, "")
      }
    _ -> take_string(string.concat(rest), acc <> first)
  }
}

/// The value a tick writes: the target's previous value plus `step`, wrapped
/// at `maximum`.
pub fn next_value(previous: Option(Int), step: Int, maximum: Int) -> Int {
  let previous = case previous {
    Some(value) -> value
    None -> 0
  }
  let next = int.max(0, previous) + step
  case maximum > 0 {
    True -> next % maximum
    False -> next
  }
}
