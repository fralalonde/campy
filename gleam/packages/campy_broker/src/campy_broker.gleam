//// The local broker's build seam: generate a designed app, compile it with a
//// `gleam build` port, and assemble a versioned artifact.
////
//// Phase 1 has no broker process and no transport. `build` runs the whole
//// pipeline in one call: `campy_appgen` writes the app source tree under
//// `generated/apps/<module_slug>/`, a port compiles it (the same port pattern
//// as `campy_hot_ffi`), and the app's own beams plus a manifest are copied to
//// `generated/broker/artifacts/<module_slug>/<version>/`. Versions are read
//// from that directory tree — there is no state file (that is T2.1).
////
//// Artifacts deliberately carry only the app's own beams
//// (`campy_app_<slug>`, `handlers_<slug>`); `campy_*` dependency beams are not
//// copied because the host VM already has them. The manifest's `modules` lists
//// what was copied, sorted.
////
//// Paths are rooted at the repository root: `CAMPY_ROOT` when the workspace
//// runner sets it, otherwise the nearest ancestor of the working directory
//// containing `campy.campy`. A failed build leaves the artifact directory
//// untouched and returns the port's error verbatim.

import campy_appgen
import campy_form/project as project_codec
import campy_manifest.{type Manifest, Capabilities, Manifest}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string

@external(erlang, "campy_broker_ffi", "run_build")
fn ffi_run_build(dir: String) -> Result(String, String)

@external(erlang, "campy_broker_ffi", "root")
fn ffi_root() -> String

@external(erlang, "campy_broker_ffi", "remove_tree")
fn ffi_remove_tree(path: String) -> Result(Nil, String)

@external(erlang, "campy_broker_ffi", "copy_file")
fn ffi_copy_file(source: String, destination: String) -> Result(Nil, String)

@external(erlang, "campy_broker_ffi", "list_versions")
fn ffi_list_versions(dir: String) -> List(Int)

/// Repository root, where `generated/` lives.
pub fn root() -> String {
  ffi_root()
}

/// Generated app source tree for one module slug.
pub fn app_dir(module_slug: String) -> String {
  root() <> "/generated/apps/" <> module_slug
}

/// Artifact root for one module slug: one subdirectory per version.
pub fn artifacts_dir(module_slug: String) -> String {
  root() <> "/generated/broker/artifacts/" <> module_slug
}

/// Artifact directory for one built version.
pub fn artifact_dir(module_slug: String, version: Int) -> String {
  artifacts_dir(module_slug) <> "/" <> int.to_string(version)
}

/// Next artifact version for an app: `1` when nothing was built yet, otherwise
/// the highest existing version plus one. Plain filesystem read; no state file.
pub fn next_version(module_slug: String) -> Int {
  case
    list.max(ffi_list_versions(artifacts_dir(module_slug)), with: int.compare)
  {
    Ok(version) -> version + 1
    Error(_) -> 1
  }
}

/// Compiles one project module into a new artifact version.
///
/// The source tree is regenerated from scratch, built, then the app's beams
/// and a manifest are assembled under `artifact_dir(slug, next_version(slug))`.
/// Returns the artifact directory and the manifest that was saved with it. Any
/// generation or build failure returns the error without creating an artifact.
pub fn build(
  project: project_codec.Project,
  module_id: String,
) -> Result(#(String, Manifest), String) {
  case project_codec.find_module(project, module_id) {
    None -> Error("unknown module: " <> module_id)
    Some(module) -> {
      let module_slug = campy_appgen.slug(module.name)
      let source_dir = app_dir(module_slug)
      let version = next_version(module_slug)
      let artifact = artifact_dir(module_slug, version)
      // Regeneration is always clean: a stale tree must never leak sources
      // from a previous build into this artifact.
      case ffi_remove_tree(source_dir) {
        Error(error) -> Error(error)
        Ok(Nil) ->
          case campy_appgen.generate(project, module_id, source_dir) {
            Error(error) -> Error(error)
            Ok(_) ->
              case ffi_run_build(source_dir) {
                // Nothing below runs, so no artifact directory is created.
                Error(error) -> Error(error)
                Ok(_output) ->
                  assemble(
                    project,
                    module,
                    module_slug,
                    source_dir,
                    version,
                    artifact,
                  )
              }
          }
      }
    }
  }
}

fn assemble(
  project: project_codec.Project,
  module: project_codec.Module,
  module_slug: String,
  source_dir: String,
  version: Int,
  artifact: String,
) -> Result(#(String, Manifest), String) {
  let entry_module = "campy_app_" <> module_slug
  let modules =
    list.sort([entry_module, "handlers_" <> module_slug], by: string.compare)
  let source_ebin =
    source_dir <> "/build/dev/erlang/" <> entry_module <> "/ebin"
  let target_ebin = artifact <> "/ebin"
  case ffi_remove_tree(artifact) {
    Error(error) -> Error(error)
    Ok(Nil) ->
      case copy_beams(modules, source_ebin, target_ebin) {
        Error(error) -> Error(error)
        Ok(Nil) -> {
          let manifest =
            Manifest(
              app: module_slug,
              title: module.name,
              version: version,
              entry_module: entry_module,
              modules: modules,
              project_path: project.path,
              module_id: module.id,
              schema: project_codec.version,
              migration: [],
              natives: [],
              capabilities: Capabilities(27, 1),
              assets: [],
              content_digest: campy_manifest.digest_dir(target_ebin),
              signature: None,
            )
          case campy_manifest.save(manifest, artifact <> "/manifest.campy") {
            Ok(Nil) -> Ok(#(artifact, manifest))
            Error(error) -> Error(error)
          }
        }
      }
  }
}

fn copy_beams(
  modules: List(String),
  source_ebin: String,
  target_ebin: String,
) -> Result(Nil, String) {
  case modules {
    [] -> Ok(Nil)
    [module, ..rest] ->
      case
        ffi_copy_file(
          source_ebin <> "/" <> module <> ".beam",
          target_ebin <> "/" <> module <> ".beam",
        )
      {
        Error(error) -> Error(error)
        Ok(Nil) -> copy_beams(rest, source_ebin, target_ebin)
      }
  }
}
