import campy_broker
import campy_form/project
import campy_manifest
import gleam/list
import gleam/option.{type Option, None}
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

// The compile tier shells out to `gleam build`; CAMPY_FAST_ONLY skips it so
// headless quick loops stay fast. Pure tests always run.
@external(erlang, "campy_broker_ffi", "getenv")
fn getenv(name: String) -> Option(String)

@external(erlang, "campy_broker_ffi", "run_build")
fn run_build(dir: String) -> Result(String, String)

@external(erlang, "campy_broker_ffi", "remove_tree")
fn remove_tree(path: String) -> Result(Nil, String)

@external(erlang, "campy_broker_ffi", "list_files")
fn list_files(directory: String) -> Result(List(String), String)

@external(erlang, "campy_broker_ffi", "write_file")
fn write_file(path: String, contents: String) -> Result(Nil, String)

@external(erlang, "campy_broker_test_ffi", "remove_tree_keeps_link_target")
fn remove_tree_keeps_link_target(path: String) -> Nil

pub fn remove_tree_keeps_link_target_test() {
  remove_tree_keeps_link_target(campy_broker.app_dir("broker_symlink_probe"))
}

fn fast_only() -> Bool {
  getenv("CAMPY_FAST_ONLY") != None
}

// `campy.campy` lives at the repository root. The workspace runner exports
// CAMPY_ROOT, so the root-relative path resolves from any package; a plain
// package-local `gleam test` falls back to paths relative to the package
// directory.
fn load_project() -> project.Project {
  case project.load("campy.campy") {
    Ok(loaded) -> loaded
    Error(_) ->
      case project.load("../../../campy.campy") {
        Ok(loaded) -> loaded
        Error(_) ->
          case project.load("../../../../campy.campy") {
            Ok(loaded) -> loaded
            Error(error) -> panic as { "cannot load campy.campy: " <> error }
          }
      }
  }
}

fn unwrap_files(result: Result(List(String), String)) -> List(String) {
  case result {
    Ok(files) -> files
    Error(error) -> panic as error
  }
}

fn is_hex_digest(digest: String) -> Bool {
  string.length(digest) == 64
  && list.all(string.to_graphemes(digest), fn(character) {
    string.contains("0123456789abcdef", character)
  })
}

// --- Pure tier: versioning and error shapes ---------------------------------

// Artifact versions are read from the directory tree, so a unique probe slug
// keeps this test off real apps; the whole probe subtree is removed first and
// last.
pub fn next_version_reads_artifact_dirs_test() {
  let slug = "broker_next_version_probe"
  let assert Ok(Nil) = remove_tree(campy_broker.artifacts_dir(slug))
  campy_broker.next_version(slug) |> should.equal(1)

  let assert Ok(Nil) =
    write_file(campy_broker.artifact_dir(slug, 2) <> "/probe", "")
  campy_broker.next_version(slug) |> should.equal(3)

  let assert Ok(Nil) =
    write_file(campy_broker.artifact_dir(slug, 7) <> "/probe", "")
  campy_broker.next_version(slug) |> should.equal(8)

  // Non-numeric and non-positive directory names are not versions.
  let assert Ok(Nil) =
    write_file(campy_broker.artifacts_dir(slug) <> "/junk/probe", "")
  let assert Ok(Nil) =
    write_file(campy_broker.artifact_dir(slug, 0) <> "/probe", "")
  campy_broker.next_version(slug) |> should.equal(8)

  remove_tree(campy_broker.artifacts_dir(slug)) |> should.equal(Ok(Nil))
}

// A directory that cannot build reports the port's error verbatim, without any
// artifact or source tree being assembled.
pub fn build_failure_error_shape_test() {
  let slug = "broker_failure_probe"
  let assert Ok(Nil) = remove_tree(campy_broker.app_dir(slug))
  let assert Ok(Nil) =
    write_file(
      campy_broker.app_dir(slug) <> "/gleam.toml",
      "this is not toml\n",
    )
  case run_build(campy_broker.app_dir(slug)) {
    Error(error) -> {
      string.starts_with(error, "gleam build failed (") |> should.be_true
    }
    Ok(_) -> panic as "expected the fake build directory to fail"
  }
  remove_tree(campy_broker.app_dir(slug)) |> should.equal(Ok(Nil))
}

pub fn unknown_module_test() {
  let loaded = load_project()
  campy_broker.build(loaded, "no-such-module")
  |> should.equal(Error("unknown module: no-such-module"))
}

// --- Compile tier: build the CCL Widgets module from campy.campy -----------

// The Cat Café demo's handler body carries manual test edits, so it is not a
// build dependency; `widgets` compiles from committed data.
pub fn build_widgets_artifact_test() {
  case fast_only() {
    True -> Nil
    False -> {
      let slug = "widgets"
      let assert Ok(Nil) = remove_tree(campy_broker.artifacts_dir(slug))
      let loaded = load_project()

      let assert Ok(#(artifact, manifest)) = campy_broker.build(loaded, slug)
      artifact |> should.equal(campy_broker.artifact_dir(slug, 1))

      // Manifest fields: slug app, first version, copied modules only, sorted.
      manifest.app |> should.equal("widgets")
      manifest.title |> should.equal("Widgets")
      manifest.version |> should.equal(1)
      manifest.entry_module |> should.equal("campy_app_widgets")
      manifest.module_id |> should.equal("widgets")
      manifest.modules
      |> should.equal(["campy_app_widgets", "handlers_widgets"])
      manifest.schema |> should.equal(project.version)
      manifest.migration |> should.equal([])
      manifest.natives |> should.equal([])
      manifest.assets |> should.equal([])
      manifest.signature |> should.equal(None)
      manifest.capabilities
      |> should.equal(campy_manifest.Capabilities(27, 1))

      // Digest covers the two copied beams and is stable for the artifact.
      is_hex_digest(manifest.content_digest) |> should.be_true
      campy_manifest.digest_dir(artifact <> "/ebin")
      |> should.equal(manifest.content_digest)

      // Exactly the manifest plus the app's own beams: no campy_* dependency
      // beams, no .app file, nothing else.
      unwrap_files(list_files(artifact))
      |> should.equal([
        "ebin/campy_app_widgets.beam",
        "ebin/handlers_widgets.beam",
        "manifest.campy",
      ])

      campy_manifest.load(artifact <> "/manifest.campy")
      |> should.equal(Ok(manifest))

      // A second build of the same module gets the next version.
      let assert Ok(#(next_artifact, next_manifest)) =
        campy_broker.build(loaded, slug)
      next_artifact |> should.equal(campy_broker.artifact_dir(slug, 2))
      next_manifest.version |> should.equal(2)
      is_hex_digest(next_manifest.content_digest) |> should.be_true
      campy_manifest.load(next_artifact <> "/manifest.campy")
      |> should.equal(Ok(next_manifest))
    }
  }
}
