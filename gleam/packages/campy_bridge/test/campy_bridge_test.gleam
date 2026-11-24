import campy_bridge
import gleam/list
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub fn loads_the_real_native_library_test() {
  campy_bridge.protocol_version() |> should.equal(2)
}

// A `LoadUi` document is the whole wire surface: check the types and the
// command constructors the IDE builds every generation with.
pub fn load_ui_document_is_a_control_tree_test() {
  let root =
    campy_bridge.ControlDesc(
      id: 0,
      kind: "panel",
      text: "Test",
      x: 0,
      y: 0,
      w: 320,
      h: 200,
      enabled: True,
      visible: True,
      props: [#("layout", campy_bridge.WireText("free"))],
      children: [
        campy_bridge.ControlDesc(
          id: 42,
          kind: "button",
          text: "Go",
          x: 8,
          y: 8,
          w: 80,
          h: 28,
          enabled: True,
          visible: True,
          props: [],
          children: [],
        ),
      ],
    )
  let command = campy_bridge.LoadUi(1, "Test", 320, 200, "dark", [root])
  case command {
    campy_bridge.LoadUi(1, "Test", 320, 200, "dark", [only]) -> {
      only.id |> should.equal(0)
      list.length(only.children) |> should.equal(1)
    }
    _ -> should.fail()
  }
}
