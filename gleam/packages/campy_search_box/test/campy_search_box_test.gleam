import campy_search_box as search
import campy_ui
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub fn typing_and_search_preserve_the_query_test() {
  let model = search.init()
  let model = search.update(model, search.QueryChanged("gleam"))
  let model = search.update(model, search.Search)
  model.query |> should.equal("gleam")
  model.busy |> should.be_true
}

pub fn component_is_a_valid_description_test() {
  search.describe() |> campy_ui.validate |> should.be_ok
}
