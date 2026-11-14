import campy_appgen
import campy_form/project
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

// The generator's FFI module is the only IO surface the tests need; the
// public API stays writer-only plus `slug`.
@external(erlang, "campy_appgen_ffi", "write_file")
fn write_file(path: String, contents: String) -> Result(Nil, String)

@external(erlang, "campy_appgen_ffi", "read_file")
fn read_file(path: String) -> Result(String, String)

@external(erlang, "campy_appgen_ffi", "list_files")
fn list_files(directory: String) -> Result(List(String), String)

// Generated trees are checked against `test/golden/<module_slug>/`. Golden
// copies of generated `.gleam` files carry a `.txt` suffix: `gleam test`
// compiles every Gleam file under `test/` (the entry module imports packages
// campy_appgen does not depend on) and `gleam format --check` parses them, so
// the goldens are stored as inert text.
//
// To regenerate: set `regenerate` to True, run `gleam test`, and commit the
// new trees. The entry module is emitted already formatted.
const regenerate = False

const scratch_root = "build/appgen-check"

fn golden_dir(module_slug: String) -> String {
  "test/golden/" <> module_slug
}

fn golden_name(path: String) -> String {
  case string.ends_with(path, ".gleam") {
    True -> path <> ".txt"
    False -> path
  }
}

// `campy.campy` lives at the repository root. `scripts/workspace.py` exports
// CAMPY_ROOT so the root-relative path resolves from any package; a
// package-local `gleam test` has no such variable, so fall back to the path
// from the package directory.
fn load_project() -> project.Project {
  case project.load("campy.campy") {
    Ok(loaded) -> loaded
    Error(_) ->
      case project.load("../../../campy.campy") {
        Ok(loaded) -> loaded
        Error(error) -> panic as { "cannot load campy.campy: " <> error }
      }
  }
}

fn module_of(project: project.Project, module_id: String) -> project.Module {
  case project.find_module(project, module_id) {
    Some(module) -> module
    None -> panic as { "campy.campy has no module " <> module_id }
  }
}

// Generate one real module into the ignored scratch tree; returns the loaded
// project, the module slug, and the generated directory.
fn generate_module(module_id: String) -> #(project.Project, String, String) {
  let loaded = load_project()
  let module = module_of(loaded, module_id)
  let module_slug = campy_appgen.slug(module.name)
  let out_dir = scratch_root <> "/" <> module_slug
  case campy_appgen.generate(loaded, module_id, out_dir) {
    Ok(directory) -> #(loaded, module_slug, directory)
    Error(error) -> panic as { "generate failed: " <> error }
  }
}

fn unwrap_files(result: Result(List(String), String)) -> List(String) {
  case result {
    Ok(files) -> files
    Error(error) -> panic as error
  }
}

fn unwrap_file(result: Result(String, String)) -> String {
  case result {
    Ok(contents) -> contents
    Error(error) -> panic as error
  }
}

fn check_golden(module_id: String) {
  let #(_, module_slug, out_dir) = generate_module(module_id)
  let generated = unwrap_files(list_files(out_dir))
  case regenerate {
    True -> {
      let target = golden_dir(module_slug)
      list.each(generated, fn(path) {
        let contents = unwrap_file(read_file(out_dir <> "/" <> path))
        let assert Ok(Nil) =
          write_file(target <> "/" <> golden_name(path), contents)
      })
    }
    False -> {
      let expected = unwrap_files(list_files(golden_dir(module_slug)))
      list.map(generated, golden_name)
      |> should.equal(expected)
      list.each(generated, fn(path) {
        let contents = unwrap_file(read_file(out_dir <> "/" <> path))
        let golden =
          unwrap_file(read_file(
            golden_dir(module_slug) <> "/" <> golden_name(path),
          ))
        contents |> should.equal(golden)
      })
    }
  }
}

// --- slug -------------------------------------------------------------------

pub fn slug_cat_cafe_test() {
  campy_appgen.slug("Cat Café") |> should.equal("cat_cafe")
}

pub fn slug_digit_prefix_test() {
  campy_appgen.slug("9lives") |> should.equal("a9lives")
}

pub fn slug_separators_test() {
  campy_appgen.slug("  Pet the cat!! ") |> should.equal("pet_the_cat")
  campy_appgen.slug("a___b") |> should.equal("a_b")
  campy_appgen.slug("Crème Brûlée") |> should.equal("creme_brulee")
}

pub fn slug_empty_test() {
  campy_appgen.slug("") |> should.equal("a")
  campy_appgen.slug("__") |> should.equal("a")
  campy_appgen.slug(" --- ") |> should.equal("a")
}

// --- golden trees -----------------------------------------------------------

pub fn golden_cat_cafe_test() {
  check_golden("cat-cafe")
}

pub fn golden_widgets_test() {
  check_golden("widgets")
}

pub fn toml_name_matches_entry_module_test() {
  let #(_, module_slug, out_dir) = generate_module("cat-cafe")
  let name = "campy_app_" <> module_slug
  let toml = unwrap_file(read_file(out_dir <> "/gleam.toml"))
  let entry = unwrap_file(read_file(out_dir <> "/src/" <> name <> ".gleam"))
  string.contains(toml, "name = \"" <> name <> "\"") |> should.be_true
  string.contains(entry, "pub const app = \"" <> module_slug <> "\"")
  |> should.be_true
  string.contains(
    toml,
    "campy_app = { path = \"../../../packages/campy_app\" }",
  )
  |> should.be_true
}

pub fn handlers_source_is_verbatim_test() {
  let #(loaded, module_slug, out_dir) = generate_module("widgets")
  let module = module_of(loaded, "widgets")
  unwrap_file(read_file(out_dir <> "/src/handlers_" <> module_slug <> ".gleam"))
  |> should.equal(module.source)
}

pub fn unknown_module_test() {
  let loaded = load_project()
  campy_appgen.generate(loaded, "no-such-module", scratch_root <> "/unknown")
  |> should.equal(Error("unknown module: no-such-module"))
}
