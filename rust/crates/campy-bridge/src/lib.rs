//! In-process BEAM boundary (protocol v2). Commands enqueue; live zgui
//! values stay on the UI thread.
//!
//! The wire types mirror `gleam/packages/campy_bridge/src/campy_bridge.gleam`
//! exactly (constructor names are the wire atoms). Conversion to the
//! renderer's `Op` happens here, before the queue.

mod lsp;

use rustler::{Atom, Encoder, Env, LocalPid, Monitor, NifTuple, OwnedEnv, Resource, ResourceArc};
use std::sync::Arc;

use campy_renderer::wire::{ControlDesc, Op, PropValue, UiDocument};

rustler::atoms! { nil, campy_event }

struct SessionResource {
    owner: LocalPid,
    session: campy_renderer::sessions::Session,
}

#[rustler::resource_impl]
impl Resource for SessionResource {
    fn down<'a>(&'a self, _env: Env<'a>, _pid: LocalPid, _monitor: Monitor) {
        self.session.close(2);
    }
}

impl Drop for SessionResource {
    fn drop(&mut self) {
        self.session.close(3);
    }
}

// --- wire decode (Gleam mirrors) ---

#[derive(rustler::NifTaggedEnum)]
#[allow(clippy::enum_variant_names)]
enum WireValue {
    WireText(String),
    WireBool(bool),
    WireInt(i64),
    WireFloat(f64),
    WireList(Vec<WireValue>),
    WireStruct(Vec<(String, WireValue)>),
    WireImage(String),
}

impl WireValue {
    fn into_prop(self) -> PropValue {
        match self {
            Self::WireText(value) => PropValue::Text(value),
            Self::WireBool(value) => PropValue::Bool(value),
            Self::WireInt(value) => PropValue::Int(value),
            Self::WireFloat(value) => PropValue::Float(value),
            Self::WireList(items) => {
                PropValue::List(items.into_iter().map(WireValue::into_prop).collect())
            }
            Self::WireStruct(fields) => PropValue::Struct(
                fields
                    .into_iter()
                    .map(|(name, value)| (name, value.into_prop()))
                    .collect(),
            ),
            Self::WireImage(path) => PropValue::Image(path),
        }
    }
}

/// Gleam `ControlDesc(...)` records decode as
/// `{control_desc, Id, Kind, Text, X, Y, W, H, Enabled, Visible, Props, Children}`.
#[derive(NifTuple)]
struct WireControl {
    tag: Atom,
    id: i64,
    kind: String,
    text: String,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    enabled: bool,
    visible: bool,
    props: Vec<(String, WireValue)>,
    children: Vec<WireControl>,
}

impl WireControl {
    fn into_desc(self) -> ControlDesc {
        ControlDesc {
            id: self.id.max(0) as u64,
            kind: self.kind,
            text: self.text,
            x: self.x,
            y: self.y,
            w: self.w,
            h: self.h,
            enabled: self.enabled,
            visible: self.visible,
            props: self
                .props
                .into_iter()
                .map(|(name, value)| (name, value.into_prop()))
                .collect(),
            children: self
                .children
                .into_iter()
                .map(WireControl::into_desc)
                .collect(),
        }
    }
}

#[derive(rustler::NifTaggedEnum)]
enum Command {
    LoadUi(i64, String, f64, f64, String, Vec<WireControl>),
    SetText(i64, i64, String),
    SetBool(i64, i64, String, bool),
    SetInt(i64, i64, String, i64),
    SetFloat(i64, i64, String, f64),
    SetModel(i64, i64, Vec<WireValue>),
    SetGeometry(i64, i64, f64, f64, f64, f64),
    SetCode(i64, i64, String),
    AppendConsole(i64, i64, String),
    SetMarks(i64, i64, String, Vec<(i64, i64, String)>),
    ReadText(i64, i64, String),
    Resize(i64, f64, f64),
    /// Several commands that belong to one moment; the outer generation wins.
    Batch(i64, Vec<Command>),
}

impl Command {
    fn split(self) -> (i64, Op) {
        match self {
            Self::LoadUi(generation, title, width, height, theme, controls) => {
                let op = Op::LoadUi(UiDocument {
                    title,
                    width,
                    height,
                    theme,
                    controls: controls.into_iter().map(WireControl::into_desc).collect(),
                });
                (generation, op)
            }
            Self::SetText(generation, control, value) => (
                generation,
                Op::SetText {
                    control: control.max(0) as u64,
                    value,
                },
            ),
            Self::SetBool(generation, control, key, value) => (
                generation,
                Op::SetBool {
                    control: control.max(0) as u64,
                    key,
                    value,
                },
            ),
            Self::SetInt(generation, control, key, value) => (
                generation,
                Op::SetInt {
                    control: control.max(0) as u64,
                    key,
                    value,
                },
            ),
            Self::SetFloat(generation, control, key, value) => (
                generation,
                Op::SetFloat {
                    control: control.max(0) as u64,
                    key,
                    value,
                },
            ),
            Self::SetModel(generation, control, items) => (
                generation,
                Op::SetModel {
                    control: control.max(0) as u64,
                    items: items.into_iter().map(WireValue::into_prop).collect(),
                },
            ),
            Self::SetGeometry(generation, control, x, y, w, h) => (
                generation,
                Op::SetGeometry {
                    control: control.max(0) as u64,
                    x,
                    y,
                    w,
                    h,
                },
            ),
            Self::SetCode(generation, control, source) => (
                generation,
                Op::SetCode {
                    control: control.max(0) as u64,
                    source,
                },
            ),
            Self::AppendConsole(generation, control, bytes) => (
                generation,
                Op::AppendConsole {
                    control: control.max(0) as u64,
                    bytes,
                },
            ),
            Self::SetMarks(generation, control, layer, items) => (
                generation,
                Op::SetMarks {
                    control: control.max(0) as u64,
                    layer,
                    items: items
                        .into_iter()
                        .map(|(start, end, class)| (start.max(0) as u64, end.max(0) as u64, class))
                        .collect(),
                },
            ),
            Self::ReadText(generation, control, key) => (
                generation,
                Op::ReadText {
                    control: control.max(0) as u64,
                    key,
                },
            ),
            Self::Resize(generation, width, height) => (generation, Op::Resize { width, height }),
            Self::Batch(generation, commands) => (
                generation,
                Op::Batch {
                    ops: commands
                        .into_iter()
                        .map(|command| command.split().1)
                        .collect(),
                },
            ),
        }
    }
}

// --- NIFs ---

#[rustler::nif]
fn protocol_version() -> u32 {
    2
}

#[rustler::nif]
fn open_session(env: Env) -> Result<ResourceArc<SessionResource>, String> {
    let owner = env.pid();
    let sink = Arc::new(
        move |session: u64, generation: u64, kind: String, payload: String| {
            let mut env = OwnedEnv::new();
            let _ = env.send_and_clear(&owner, |env| {
                (campy_event(), session, generation, kind, payload).encode(env)
            });
        },
    );
    let session = campy_renderer::sessions::open(sink)?;
    let resource = ResourceArc::new(SessionResource { owner, session });
    if resource.monitor(Some(env), &owner).is_none() {
        resource.session.close(2);
        return Err("Cannot monitor session owner".into());
    }
    Ok(resource)
}

fn authorize(env: Env, resource: &SessionResource) -> Result<(), String> {
    if env.pid() != resource.owner {
        Err("Only the session owner may issue UI commands".into())
    } else {
        Ok(())
    }
}

#[rustler::nif]
fn session_id(env: Env, resource: ResourceArc<SessionResource>) -> Result<u64, String> {
    authorize(env, &resource)?;
    Ok(resource.session.id())
}

#[rustler::nif]
fn submit(
    env: Env,
    resource: ResourceArc<SessionResource>,
    command: Command,
) -> Result<rustler::Atom, String> {
    authorize(env, &resource)?;
    let (generation, op) = command.split();
    let generation = generation.max(0) as u64;
    resource
        .session
        .submit(campy_renderer::sessions::Command { generation, op })?;
    Ok(nil())
}

#[rustler::nif]
fn close_session(
    env: Env,
    resource: ResourceArc<SessionResource>,
) -> Result<rustler::Atom, String> {
    authorize(env, &resource)?;
    resource.session.close(1);
    Ok(nil())
}

#[rustler::nif]
fn active_sessions() -> u64 {
    campy_renderer::sessions::active_sessions() as u64
}

// --- headless smoke driver (ui-testing feature) ---

#[cfg(feature = "ui-testing")]
#[rustler::nif]
fn test_pump(milliseconds: u64) -> Result<u64, String> {
    campy_renderer::testing::test_pump(milliseconds)
}

#[cfg(feature = "ui-testing")]
#[rustler::nif]
fn test_pointer(action: String, x: f32, y: f32) -> Result<rustler::Atom, String> {
    campy_renderer::testing::test_pointer(&action, x, y)?;
    Ok(nil())
}

#[cfg(feature = "ui-testing")]
#[rustler::nif]
fn test_resize(width: f32, height: f32) -> Result<rustler::Atom, String> {
    campy_renderer::testing::test_resize(width, height)?;
    Ok(nil())
}

// NIFs register themselves via inventory (including the lsp module's).
rustler::init!("campy_bridge_ffi");
