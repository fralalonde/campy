//// Renderer gallery: exercises mount, patches, keyed children, and events.
////
//// Run interactively with `gleam run -m campy_wx/gallery` in a display session.
//// Set CAMPY_WX_SMOKE=1 for a scripted mount/patch/close run that exits 0.

import campy_view.{type Node, VBool, VInt, VList, VNull, VText}
import campy_view/diff
import campy_wx
import gleam/float as gleam_float
import gleam/int
import gleam/io
import gleam/list

pub fn main() {
  case campy_wx.getenv("CAMPY_WX_SMOKE") {
    "1" -> smoke()
    _ -> interactive()
  }
}

fn interactive() {
  let shell = campy_wx.start("Campy wx gallery", 620, 560)
  let view = build_view(0, "ready")

  let started = campy_wx.now_ms()
  let assert Ok(shell) = campy_wx.mount(shell, view)
  io.println(
    "[gallery] mount " <> int.to_string(campy_wx.now_ms() - started) <> "ms",
  )

  campy_wx.focus(shell, "query")
  loop(shell, view, 0, "ready", 0)
}

fn smoke() {
  let shell = campy_wx.start("Campy wx smoke", 480, 360)
  let view = build_view(0, "smoke")

  let started = campy_wx.now_ms()
  let assert Ok(shell) = campy_wx.mount(shell, view)
  io.println("[gallery] smoke mount " <> elapsed(started))

  let #(shell, _view) = update(shell, view, build_view(0, "patched"))
  let #(shell, _view) = update(shell, view, build_view(1, "reordered"))
  let #(shell, view) = update(shell, view, build_view(2, "disabled"))

  let #(shell, _view) = update(shell, view, build_view(3, "ready again"))

  campy_wx.close(shell)
  io.println("[gallery] smoke ok")
}

fn loop(
  shell: campy_wx.Shell,
  view: Node,
  phase: Int,
  status: String,
  tick: Int,
) {
  case campy_wx.next(shell, 50) {
    campy_wx.Closed -> {
      campy_wx.close(shell)
      io.println("[gallery] closed")
    }
    campy_wx.Event(id, key, value) -> {
      io.println(
        "[gallery] event " <> id <> "." <> key <> " = " <> render(value),
      )
      case id, key {
        "mutate", "click" -> {
          let phase = { phase + 1 } % 4
          let #(shell, view) = update(shell, view, build_view(phase, status))
          loop(shell, view, phase, status, tick + 1)
        }
        _, _ -> loop(shell, view, phase, status, tick + 1)
      }
    }
    campy_wx.Paint(id) -> {
      campy_wx.paint(shell, id)
      loop(shell, view, phase, status, tick + 1)
    }
    campy_wx.MouseHandle(_, _, _, _) ->
      loop(shell, view, phase, status, tick + 1)
    campy_wx.Mouse(_, _, _, _) -> loop(shell, view, phase, status, tick + 1)
    campy_wx.Message(_message) -> loop(shell, view, phase, status, tick + 1)
    campy_wx.Idle -> {
      case tick % 40 {
        0 -> {
          let status = "tick " <> int.to_string(tick)
          let #(shell, view) = update(shell, view, build_view(phase, status))
          loop(shell, view, phase, status, tick + 1)
        }
        _ -> loop(shell, view, phase, status, tick + 1)
      }
    }
  }
}

fn update(
  shell: campy_wx.Shell,
  previous: Node,
  next: Node,
) -> #(campy_wx.Shell, Node) {
  let patches = diff.diff(previous, next)
  let started = campy_wx.now_ms()

  case campy_wx.apply(shell, patches) {
    Ok(shell) -> {
      io.println(
        "[gallery] apply "
        <> int.to_string(list.length(patches))
        <> " patches in "
        <> elapsed(started),
      )
      #(shell, next)
    }
    Error(error) -> {
      io.println("[gallery] apply failed: " <> error)
      #(shell, previous)
    }
  }
}

fn elapsed(since: Int) -> String {
  int.to_string(campy_wx.now_ms() - since) <> "ms"
}

fn render(value: campy_view.Value) -> String {
  case value {
    VText(text) -> text
    VInt(number) -> int.to_string(number)
    VBool(flag) ->
      case flag {
        True -> "true"
        False -> "false"
      }
    VList(_items) -> "[list]"
    campy_view.VMap(_fields) -> "[map]"
    campy_view.VFloat(number) -> gleam_float.to_string(number)
    VNull -> "null"
  }
}

fn build_view(phase: Int, status: String) -> Node {
  let inserted = phase == 0
  let reordered = phase == 1
  let enabled = phase != 2

  campy_view.node("panel", "gallery")
  |> campy_view.with_props([
    #("layout", VText("column")),
    #("border", VInt(8)),
  ])
  |> campy_view.with_children([
    campy_view.node("panel", "buttons")
      |> campy_view.with_props([
        #("layout", VText("row")),
        #("border", VInt(4)),
      ])
      |> campy_view.with_children([
        campy_view.node("label", "title")
          |> campy_view.with_props([#("text", VText("Campy wx gallery"))]),
        campy_view.node("button", "mutate")
          |> campy_view.with_props([
            #("text", VText("Mutate")),
            #("enabled", VBool(enabled)),
          ])
          |> campy_view.with_events(["click"]),
        campy_view.node("checkbox", "enabled")
          |> campy_view.with_props([
            #("text", VText("Enabled")),
            #("checked", VBool(True)),
          ])
          |> campy_view.with_events(["click"]),
      ]),
    campy_view.node("text", "query")
      |> campy_view.with_props([
        #("text", VText("type here")),
        #("w", VInt(320)),
      ])
      |> campy_view.with_events(["change"]),
    campy_view.node("choice", "choice")
      |> campy_view.with_props([
        #("items", VList([VText("One"), VText("Two"), VText("Three")])),
        #("w", VInt(160)),
      ])
      |> campy_view.with_events(["change"]),
    campy_view.node("slider", "slider")
      |> campy_view.with_props([
        #("value", VInt(40)),
        #("min", VInt(0)),
        #("max", VInt(100)),
        #("w", VInt(240)),
      ])
      |> campy_view.with_events(["change"]),
    campy_view.node("progress", "progress")
      |> campy_view.with_props([
        #("value", VInt(40)),
        #("max", VInt(100)),
        #("w", VInt(240)),
      ]),
    campy_view.node("list", "rows")
      |> campy_view.with_props([
        #("items", VList(row_items())),
        #("w", VInt(320)),
        #("h", VInt(120)),
      ])
      |> campy_view.with_events(["change"]),
    campy_view.node("label", "status")
      |> campy_view.with_props([#("text", VText(status))]),
    rows_panel(inserted, reordered),
  ])
}

fn rows_panel(inserted: Bool, reordered: Bool) -> Node {
  let first =
    campy_view.node("label", "row-a")
    |> campy_view.with_props([#("text", VText("row A"))])
  let second =
    campy_view.node("label", "row-b")
    |> campy_view.with_props([#("text", VText("row B"))])

  let children = case reordered {
    True -> [second, first]
    False -> [first, second]
  }

  let children = case inserted {
    True ->
      list.append(children, [
        campy_view.node("label", "row-extra")
        |> campy_view.with_props([#("text", VText("inserted row"))]),
      ])
    False -> children
  }

  campy_view.node("panel", "row-panel")
  |> campy_view.with_props([
    #("layout", VText("column")),
    #("border", VInt(2)),
  ])
  |> campy_view.with_children(children)
}

fn row_items() -> List(campy_view.Value) {
  range(1, 500)
  |> list.map(fn(index) { VText("Row " <> int.to_string(index)) })
}

fn range(from: Int, to: Int) -> List(Int) {
  case from > to {
    True -> []
    False -> [from, ..range(from + 1, to)]
  }
}
