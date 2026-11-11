import campy_ui as ui

pub type Model {
  Model(query: String, busy: Bool)
}

// Handwritten for the first slice; generated from the component schema in M1.
pub type Event {
  QueryChanged(String)
  Search
}

pub fn init() -> Model {
  Model(query: "", busy: False)
}

pub fn update(model: Model, event: Event) -> Model {
  case event {
    QueryChanged(query) -> Model(..model, query: query)
    Search -> Model(..model, busy: True)
  }
}

// Edit the title, label, or layout while `just dev` is running.
// The package has no Rust dependency and contains no handwritten Slint.
pub fn describe() -> ui.Definition {
  ui.Definition(
    id: "campy.search-box",
    title: "Campy — Search box",
    body: ui.Row(id: "root-layout", children: [
      ui.TextField(id: "query-input", value: ui.Query),
      ui.Button(
        id: "search-button",
        text: ui.TextLiteral("Search"),
        enabled: ui.Not(ui.Busy),
      ),
    ]),
  )
}
