import campy_form/project.{type Project}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}

// A workspace holds several independent projects. Each project keeps its own
// modules, form model, handler source, and path. Campy persists the workspace
// automatically (see the IDE host), so switching or closing the window does not
// lose edits even when a project file was not explicitly saved.
pub type Workspace {
  Workspace(version: Int, projects: List(Project), active: String, path: String)
}

pub const version = 1

pub const default_path = "projects/workspace.campy"

@external(erlang, "campy_form_ffi", "save_workspace")
fn write(path: String, workspace: Workspace) -> Result(Nil, String)

@external(erlang, "campy_form_ffi", "load_workspace")
fn read(path: String) -> Result(Workspace, String)

pub fn new(project: Project) -> Workspace {
  Workspace(version, [project], project.path, default_path)
}

pub fn count(workspace: Workspace) -> Int {
  list.length(workspace.projects)
}

pub fn active_project(workspace: Workspace) -> Option(Project) {
  find(workspace, workspace.active)
}

pub fn find(workspace: Workspace, path: String) -> Option(Project) {
  case list.find(workspace.projects, fn(project) { project.path == path }) {
    Ok(project) -> Some(project)
    Error(_) -> None
  }
}

pub fn contains(workspace: Workspace, path: String) -> Bool {
  list.any(workspace.projects, fn(project) { project.path == path })
}

pub fn switch(workspace: Workspace, path: String) -> Workspace {
  Workspace(..workspace, active: path)
}

// Replace the project with the same path, or append a new one, and activate it.
pub fn upsert(workspace: Workspace, project: Project) -> Workspace {
  let exists = contains(workspace, project.path)
  let projects = case exists {
    True ->
      list.map(workspace.projects, fn(item) {
        case item.path == project.path {
          True -> project
          False -> item
        }
      })
    False -> list.append(workspace.projects, [project])
  }
  Workspace(..workspace, projects: projects, active: project.path)
}

// Save the current project copy into the workspace (in place).
pub fn update_active(workspace: Workspace, project: Project) -> Workspace {
  let projects =
    list.map(workspace.projects, fn(item) {
      case item.path == project.path {
        True -> project
        False -> item
      }
    })
  Workspace(..workspace, projects: projects, active: project.path)
}

// Used by Save As: the active project moved to a new path.
pub fn replace_path(
  workspace: Workspace,
  old_path: String,
  project: Project,
) -> Workspace {
  let remaining =
    list.filter(workspace.projects, fn(item) {
      item.path != old_path && item.path != project.path
    })
  Workspace(
    ..workspace,
    projects: list.append(remaining, [project]),
    active: project.path,
  )
}

pub fn remove(workspace: Workspace, path: String) -> Workspace {
  let projects =
    list.filter(workspace.projects, fn(project) { project.path != path })
  case projects {
    [] -> workspace
    _ ->
      case workspace.active == path {
        True -> {
          let assert [first, ..] = projects
          Workspace(..workspace, projects: projects, active: first.path)
        }
        False -> Workspace(..workspace, projects: projects)
      }
  }
}

pub fn save(workspace: Workspace) -> Result(Nil, String) {
  write(workspace.path, workspace)
}

pub fn save_at(
  workspace: Workspace,
  path: String,
) -> Result(Workspace, String) {
  let next = Workspace(..workspace, path: path)
  case write(path, next) {
    Ok(_) -> Ok(next)
    Error(error) -> Error(error)
  }
}

pub fn load(path: String) -> Result(Workspace, String) {
  case read(path) {
    Error(error) -> Error(error)
    Ok(workspace) ->
      case workspace.projects {
        [] -> Error("Workspace contains no projects")
        [first, ..] -> {
          let active = case find(workspace, workspace.active) {
            Some(project) -> project.path
            None -> first.path
          }
          Ok(Workspace(..workspace, active: active, path: path))
        }
      }
  }
}

// First unused generated project path, e.g. projects/project-2.campy.
pub fn next_project_number(workspace: Workspace) -> Int {
  next_number(workspace, 1)
}

fn next_number(workspace: Workspace, start: Int) -> Int {
  let path = "projects/project-" <> int.to_string(start) <> ".campy"
  case contains(workspace, path) {
    True -> next_number(workspace, start + 1)
    False -> start
  }
}
