import campy_form/project
import campy_manifest
import gleam/int
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should

@external(erlang, "campy_manifest_test_ffi", "temp_dir")
fn temp_dir(prefix: String) -> String

@external(erlang, "campy_manifest_test_ffi", "fixture_dir")
fn fixture_dir(name: String) -> String

@external(erlang, "campy_manifest_test_ffi", "copy_dir")
fn copy_dir(from: String, to: String) -> Result(Nil, String)

@external(erlang, "campy_manifest_test_ffi", "append_bytes")
fn append_bytes(path: String, extra: String) -> Result(Nil, String)

@external(erlang, "campy_manifest_test_ffi", "write_version_2_manifest")
fn write_version_2_manifest(path: String) -> Result(Nil, String)

pub fn main() {
  gleeunit.main()
}

fn sample() -> campy_manifest.Manifest {
  campy_manifest.Manifest(
    app: "cat_cafe",
    title: "Cat Café",
    version: 3,
    entry_module: "campy_app_cat_cafe",
    modules: ["campy_app_cat_cafe", "handlers_cat_cafe"],
    project_path: "campy.campy",
    module_id: "cat-cafe",
    schema: project.version,
    migration: [
      campy_manifest.Step(9, 10, "control colors"),
      campy_manifest.Step(10, 11, "property values"),
    ],
    natives: [
      campy_manifest.Native("linux-x86_64", "abc123", "priv/cat.so"),
    ],
    capabilities: campy_manifest.Capabilities(27, 1),
    assets: ["assets/cat.png"],
    content_digest: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    signature: Some("reserved"),
  )
}

pub fn save_load_round_trip_test() {
  let path = temp_dir("campy-manifest") <> "/manifest.campy"
  campy_manifest.save(sample(), path) |> should.equal(Ok(Nil))
  campy_manifest.load(path) |> should.equal(Ok(sample()))
}

pub fn save_load_round_trip_without_signature_test() {
  let path = temp_dir("campy-manifest") <> "/manifest.campy"
  let manifest = campy_manifest.Manifest(..sample(), signature: None)
  campy_manifest.save(manifest, path) |> should.equal(Ok(Nil))
  campy_manifest.load(path) |> should.equal(Ok(manifest))
}

pub fn rejects_unsupported_version_tag_test() {
  let path = temp_dir("campy-manifest") <> "/manifest.campy"
  write_version_2_manifest(path) |> should.equal(Ok(Nil))
  case campy_manifest.load(path) {
    Ok(_) -> should.fail()
    Error(message) ->
      string.contains(message, "unsupported manifest version")
      |> should.be_true()
  }
}

pub fn to_summary_renders_exact_line_test() {
  campy_manifest.to_summary(sample())
  |> should.equal(
    "cat_cafe v3 schema" <> int.to_string(project.version) <> " digest01234567",
  )
}

pub fn default_has_phase_one_capabilities_test() {
  campy_manifest.default().capabilities
  |> should.equal(campy_manifest.Capabilities(27, 1))
  campy_manifest.default().signature |> should.equal(None)
}

pub fn digest_dir_is_stable_test() {
  let dir = fixture_dir("ebin")
  let first = campy_manifest.digest_dir(dir)
  string.length(first) |> should.equal(64)
  campy_manifest.digest_dir(dir) |> should.equal(first)
}

pub fn digest_dir_changes_when_a_beam_changes_test() {
  let source = fixture_dir("ebin")
  let copy = temp_dir("campy-manifest-digest") <> "/ebin"
  copy_dir(source, copy) |> should.equal(Ok(Nil))
  let before = campy_manifest.digest_dir(copy)
  append_bytes(copy <> "/beta.beam", "\nchanged\n") |> should.equal(Ok(Nil))
  let after = campy_manifest.digest_dir(copy)
  string.length(before) |> should.equal(64)
  after |> should.not_equal(before)
}
