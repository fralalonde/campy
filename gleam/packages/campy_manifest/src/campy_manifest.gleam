//// The artifact manifest: the contract between the broker, the runner, and
//// (later) the IDE transport.
////
//// A manifest describes one built version of a designed app. It is stored
//// next to the artifact as a versioned compressed Erlang term
//// (`manifest.campy`), following the codec pattern of
//// `campy_form/project.gleam`: an explicit format version tag, validation on
//// load, and explicit errors on mismatch.

import gleam/int
import gleam/option.{type Option, None}
import gleam/string

pub type Native {
  Native(target: String, digest: String, path: String)
}

pub type Capabilities {
  Capabilities(otp_min: Int, bridge_protocol: Int)
}

pub type Step {
  Step(from: Int, to: Int, note: String)
}

pub type Manifest {
  Manifest(
    app: String,
    title: String,
    version: Int,
    entry_module: String,
    modules: List(String),
    project_path: String,
    module_id: String,
    schema: Int,
    migration: List(Step),
    natives: List(Native),
    capabilities: Capabilities,
    assets: List(String),
    content_digest: String,
    signature: Option(String),
  )
}

/// On-disk manifest format version.
pub const format_version = 1

@external(erlang, "campy_manifest_ffi", "save_manifest")
fn write_manifest(path: String, manifest: Manifest) -> Result(Nil, String)

@external(erlang, "campy_manifest_ffi", "load_manifest")
fn read_manifest(path: String) -> Result(Manifest, String)

@external(erlang, "campy_manifest_ffi", "digest_dir")
fn ffi_digest_dir(ebin_dir: String) -> String

/// Writes `manifest` as a versioned compressed Erlang term to `path`.
pub fn save(manifest: Manifest, path: String) -> Result(Nil, String) {
  write_manifest(path, manifest)
}

/// Reads and validates a manifest written by `save`.
pub fn load(path: String) -> Result(Manifest, String) {
  read_manifest(path)
}

/// sha256 hex digest over the `*.beam` files in `ebin_dir`.
///
/// Hashes the concatenation of each file's relative path, size, and sha256, in
/// sorted-path order. Returns an empty string when the directory holds no
/// readable beam files.
pub fn digest_dir(ebin_dir: String) -> String {
  ffi_digest_dir(ebin_dir)
}

/// A blank manifest with the phase-1 OTP/bridge capabilities.
///
/// Callers fill in the app fields; `schema` is the project codec version the
/// form came from and is left at 0 for the caller to set.
pub fn default() -> Manifest {
  Manifest(
    app: "",
    title: "",
    version: 0,
    entry_module: "",
    modules: [],
    project_path: "",
    module_id: "",
    schema: 0,
    migration: [],
    natives: [],
    capabilities: Capabilities(27, 1),
    assets: [],
    content_digest: "",
    signature: None,
  )
}

/// One console line: `"<app> v<version> schema<schema> digest<first 8 hex>"`.
pub fn to_summary(manifest: Manifest) -> String {
  manifest.app
  <> " v"
  <> int.to_string(manifest.version)
  <> " schema"
  <> int.to_string(manifest.schema)
  <> " digest"
  <> string.slice(manifest.content_digest, 0, 8)
}
