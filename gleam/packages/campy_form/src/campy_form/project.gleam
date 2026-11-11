import campy_form.{
  type Form, Button, CheckBox, ComboBox, EditBox, Label, ListBox, Memo, Menu,
  Panel, Picture, Progress, RadioButton, Slider,
}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

// A Campy project is a set of modules. Each module owns one form and its
// handler source, the way a Delphi/Lazarus unit owns a form and its code.
pub type Module {
  Module(id: String, name: String, form: Form, source: String)
}

pub type Project {
  Project(
    version: Int,
    title: String,
    modules: List(Module),
    path: String,
    icon: String,
  )
}

pub const version = 7

pub const camping_icon = "assets/camping-tent.png"

pub const default_path = "projects/campy.campy"

@external(erlang, "campy_form_ffi", "save_project")
fn write_project(path: String, project: Project) -> Result(Nil, String)

@external(erlang, "campy_form_ffi", "load_project")
fn read_project(path: String) -> Result(Project, String)

// Campy opens itself: the default project is the IDE's own project file with
// its first demo application (a tiny cat café).
pub fn campy() -> Project {
  Project(
    version,
    "Campy",
    [
      Module("cat-cafe", "Cat Café", cat_cafe_form(), cat_cafe_source()),
      Module("widgets", "Widgets", widgets_form(), widgets_source()),
      Module("welcome", "Welcome", welcome_form(), welcome_source()),
      Module("search-box", "Search box", search_form(), search_source()),
    ],
    default_path,
    camping_icon,
  )
}

pub fn new() -> Project {
  Project(
    version,
    "Campy",
    [Module("main", "Main", campy_form.new_form(), campy_form.default_source())],
    default_path,
    "",
  )
}

fn cat_cafe_form() -> Form {
  campy_form.Form(
    "campy.form",
    "Cat Café",
    640,
    420,
    campy_form.Free,
    [
      campy_form.Control(
        "panel-1",
        "panel1",
        Panel,
        24,
        24,
        560,
        360,
        "Cat Café",
        True,
        True,
      ),
      campy_form.Control(
        "picture-1",
        "picture1",
        Picture,
        44,
        68,
        200,
        150,
        "assets/cat.png",
        True,
        True,
      ),
      campy_form.Control(
        "label-1",
        "label1",
        Label,
        264,
        68,
        280,
        24,
        "Mochi says hello!",
        True,
        True,
      ),
      campy_form.Control(
        "list-1",
        "list1",
        ListBox,
        264,
        104,
        280,
        78,
        "Resident cats",
        True,
        True,
      ),
      campy_form.Control(
        "search-edit",
        "search_edit",
        EditBox,
        264,
        192,
        280,
        32,
        "",
        True,
        True,
      ),
      campy_form.Control(
        "pet-button",
        "pet_button",
        Button,
        44,
        236,
        140,
        32,
        "Pet the cat",
        True,
        True,
      ),
      campy_form.Control(
        "feed-button",
        "feed_button",
        Button,
        196,
        236,
        140,
        32,
        "Feed the cat",
        True,
        True,
      ),
    ],
    [
      #("picture-1", "panel-1"),
      #("label-1", "panel-1"),
      #("list-1", "panel-1"),
      #("search-edit", "panel-1"),
      #("pet-button", "panel-1"),
      #("feed-button", "panel-1"),
    ],
    [],
    [],
  )
}

fn widgets_form() -> Form {
  campy_form.Form(
    "campy.form",
    "Widgets",
    640,
    460,
    campy_form.Free,
    [
      campy_form.Control(
        "header",
        "header",
        Label,
        0,
        0,
        640,
        22,
        "CCL · Campy Component Library",
        True,
        True,
      ),
      campy_form.Control(
        "panel-1",
        "panel1",
        Panel,
        24,
        36,
        592,
        390,
        "CCL widgets",
        True,
        True,
      ),
      campy_form.Control(
        "label-1",
        "label1",
        Label,
        44,
        64,
        300,
        24,
        "Campy Component Library",
        True,
        True,
      ),
      campy_form.Control(
        "checkbox-1",
        "checkbox1",
        CheckBox,
        44,
        104,
        180,
        28,
        "Purr mode",
        True,
        True,
      ),
      campy_form.Control(
        "radio-1",
        "radio1",
        RadioButton,
        44,
        140,
        180,
        28,
        "Cat person",
        True,
        True,
      ),
      campy_form.Control(
        "radio-2",
        "radio2",
        RadioButton,
        240,
        140,
        180,
        28,
        "Dog person",
        True,
        True,
      ),
      campy_form.Control(
        "combo-1",
        "combo1",
        ComboBox,
        44,
        180,
        200,
        32,
        "",
        True,
        True,
      ),
      campy_form.Control(
        "slider-1",
        "slider1",
        Slider,
        264,
        180,
        200,
        32,
        "70",
        True,
        True,
      ),
      campy_form.Control(
        "progress-1",
        "progress1",
        Progress,
        44,
        224,
        200,
        24,
        "80",
        True,
        True,
      ),
      campy_form.Control(
        "memo-1",
        "memo1",
        Memo,
        44,
        264,
        300,
        100,
        "Meow!\nPurr purr.",
        True,
        True,
      ),
      campy_form.Control(
        "button-1",
        "button1",
        Button,
        364,
        264,
        140,
        32,
        "Feed",
        True,
        True,
      ),
      campy_form.Control(
        "footer",
        "footer",
        Label,
        0,
        0,
        640,
        24,
        "Free layout · Top/Bottom aligned labels",
        True,
        True,
      ),
    ],
    [
      #("label-1", "panel-1"),
      #("checkbox-1", "panel-1"),
      #("radio-1", "panel-1"),
      #("radio-2", "panel-1"),
      #("combo-1", "panel-1"),
      #("slider-1", "panel-1"),
      #("progress-1", "panel-1"),
      #("memo-1", "panel-1"),
      #("button-1", "panel-1"),
    ],
    [#("header", campy_form.Top), #("footer", campy_form.Bottom)],
    [],
  )
}

fn widgets_source() -> String {
  "// CCL widget handlers.\n\npub fn checkbox1_toggled() -> Nil {\n  Nil\n}\n\npub fn radio1_clicked() -> Nil {\n  Nil\n}\n\npub fn radio2_clicked() -> Nil {\n  Nil\n}\n\npub fn combo1_selected() -> Nil {\n  Nil\n}\n\npub fn slider1_changed() -> Nil {\n  Nil\n}\n\npub fn memo1_changed() -> Nil {\n  Nil\n}\n\npub fn button1_clicked() -> Nil {\n  Nil\n}\n"
}

fn cat_cafe_source() -> String {
  "// Cat Café handlers.\n\npub fn pet_button_clicked() -> Nil {\n  // TODO: purr.\n  Nil\n}\n\npub fn feed_button_clicked() -> Nil {\n  // TODO: serve a snack.\n  Nil\n}\n"
}

fn welcome_form() -> Form {
  campy_form.Form(
    "campy.form",
    "Welcome",
    640,
    420,
    campy_form.Free,
    [
      campy_form.Control(
        "menu-1",
        "menu1",
        Menu,
        24,
        16,
        180,
        28,
        "File",
        True,
        True,
      ),
      campy_form.Control(
        "label-1",
        "label1",
        Label,
        24,
        60,
        300,
        24,
        "Welcome to Campy",
        True,
        True,
      ),
      campy_form.Control(
        "edit-1",
        "edit1",
        EditBox,
        24,
        100,
        240,
        32,
        "",
        True,
        True,
      ),
      campy_form.Control(
        "button-1",
        "button1",
        Button,
        24,
        148,
        110,
        32,
        "Start",
        True,
        True,
      ),
    ],
    [],
    [],
    [],
  )
}

fn welcome_source() -> String {
  "// Campy event handlers for \"Welcome\".\n\npub fn menu1_selected() -> Nil {\n  // TODO: implement the menu action.\n  Nil\n}\n\npub fn button1_clicked() -> Nil {\n  // TODO: implement the welcome action.\n  Nil\n}\n"
}

fn search_form() -> Form {
  campy_form.Form(
    "campy.form",
    "Search box",
    640,
    420,
    campy_form.Free,
    [
      campy_form.Control(
        "label-1",
        "label1",
        Label,
        24,
        24,
        300,
        24,
        "Search documents",
        True,
        True,
      ),
      campy_form.Control(
        "edit-1",
        "edit1",
        EditBox,
        24,
        64,
        300,
        32,
        "",
        True,
        True,
      ),
      campy_form.Control(
        "button-1",
        "button1",
        Button,
        24,
        112,
        110,
        32,
        "Search",
        True,
        True,
      ),
    ],
    [],
    [],
    [],
  )
}

fn search_source() -> String {
  "// Campy event handlers for \"Search box\".\n\npub fn button1_clicked() -> Nil {\n  // TODO: implement the search action.\n  Nil\n}\n"
}

pub fn new_project(title: String, path: String) -> Project {
  let form = campy_form.Form(..campy_form.new_form(), title: title)
  Project(
    version,
    title,
    [Module("main", "Main", form, campy_form.default_source())],
    path,
    "",
  )
}

pub fn find_module(project: Project, id: String) -> Option(Module) {
  list.find(project.modules, fn(module) { module.id == id })
  |> to_option
}

pub fn update_module(project: Project, updated: Module) -> Project {
  Project(
    ..project,
    modules: list.map(project.modules, fn(module) {
      case module.id == updated.id {
        True -> updated
        False -> module
      }
    }),
  )
}

pub fn add_module(project: Project, module: Module) -> Project {
  Project(..project, modules: list.append(project.modules, [module]))
}

pub fn remove_module(project: Project, id: String) -> Project {
  Project(
    ..project,
    modules: list.filter(project.modules, fn(module) { module.id != id }),
  )
}

pub fn save(project: Project, path: String) -> Result(Project, String) {
  let next = Project(..project, path: path)
  case write_project(path, next) {
    Ok(_) -> Ok(next)
    Error(error) -> Error(error)
  }
}

pub fn save_current(project: Project) -> Result(Project, String) {
  save(project, project.path)
}

pub fn load(path: String) -> Result(Project, String) {
  case read_project(path) {
    Error(error) -> Error(error)
    Ok(project) ->
      case project.version == version {
        False -> Error("Unsupported project version")
        True ->
          result.map(validate(project), fn(next) { Project(..next, path: path) })
      }
  }
}

fn validate(project: Project) -> Result(Project, String) {
  case project.modules {
    [] -> Error("A project must contain at least one module")
    modules -> {
      let ids = list.map(modules, fn(module) { module.id })
      let names = list.map(modules, fn(module) { module.name })
      case list.length(ids) == list.length(list.unique(ids)) {
        False -> Error("Module IDs must be unique")
        True ->
          case list.length(names) == list.length(list.unique(names)) {
            False -> Error("Module names must be unique")
            True ->
              case validate_forms(modules) {
                Ok(forms) -> Ok(Project(..project, modules: forms))
                Error(error) -> Error(error)
              }
          }
      }
    }
  }
}

fn validate_forms(modules: List(Module)) -> Result(List(Module), String) {
  validate_forms_loop(modules, [])
}

fn validate_forms_loop(
  remaining: List(Module),
  checked: List(Module),
) -> Result(List(Module), String) {
  case remaining {
    [] -> Ok(list.reverse(checked))
    [module, ..rest] ->
      case campy_form.validate(module.form) {
        Error(error) -> Error(error)
        Ok(form) ->
          validate_forms_loop(rest, [Module(..module, form: form), ..checked])
      }
  }
}

fn to_option(result: Result(a, Nil)) -> Option(a) {
  case result {
    Ok(value) -> Some(value)
    Error(_) -> None
  }
}
