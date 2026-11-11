//! In-process BEAM boundary. Commands enqueue; live UI values stay on the UI thread.

use rustler::{Encoder, Env, LocalPid, Monitor, OwnedEnv, Resource, ResourceArc};
use std::sync::Arc;

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

#[derive(rustler::NifTaggedEnum)]
enum WireValue {
    WireText(String),
    WireBool(bool),
    WireInt(i64),
    WireList(Vec<WireValue>),
    WireStruct(Vec<(String, WireValue)>),
    WireImage(String),
}

impl WireValue {
    fn into_prop(self) -> campy_renderer::sessions::PropValue {
        use campy_renderer::sessions::PropValue;
        match self {
            WireValue::WireText(value) => PropValue::Text(value),
            WireValue::WireBool(value) => PropValue::Bool(value),
            WireValue::WireInt(value) => PropValue::Int(value),
            WireValue::WireList(items) => {
                PropValue::List(items.into_iter().map(WireValue::into_prop).collect())
            }
            WireValue::WireStruct(fields) => PropValue::Struct(
                fields
                    .into_iter()
                    .map(|(name, value)| (name, value.into_prop()))
                    .collect(),
            ),
            WireValue::WireImage(path) => PropValue::Image(path),
        }
    }
}

#[derive(rustler::NifTaggedEnum)]
enum Command {
    LoadUi(u64, String),
    SetText(u64, String, String),
    SetBool(u64, String, bool),
    SetInt(u64, String, i64),
    SetModel(u64, String, Vec<WireValue>),
    SetColor(u64, String, String),
    ReadText(u64, String),
    Resize(u64, u32, u32),
    Snapshot(u64, String),
}

impl From<Command> for campy_renderer::sessions::Command {
    fn from(command: Command) -> Self {
        use campy_renderer::sessions::Command as Native;
        match command {
            Command::LoadUi(g, s) => Native::LoadUi(g, s),
            Command::SetText(g, p, v) => Native::SetText(g, p, v),
            Command::SetBool(g, p, v) => Native::SetBool(g, p, v),
            Command::SetInt(g, p, v) => Native::SetInt(g, p, v),
            Command::SetModel(g, p, items) => Native::SetModel(
                g,
                p,
                items
                    .into_iter()
                    .map(WireValue::into_prop)
                    .collect::<Vec<_>>(),
            ),
            Command::SetColor(g, p, v) => Native::SetColor(g, p, v),
            Command::ReadText(g, p) => Native::ReadText(g, p),
            Command::Resize(g, w, h) => Native::Resize(g, w, h),
            Command::Snapshot(g, p) => Native::Snapshot(g, p),
        }
    }
}

#[rustler::nif]
fn protocol_version() -> u32 {
    1
}

#[rustler::nif(schedule = "DirtyIo")]
fn validate_ui(source: String) -> Result<u64, String> {
    campy_renderer::validate(&source).map(|count| count as u64)
}

#[rustler::nif]
fn open_session(env: Env) -> Result<ResourceArc<SessionResource>, String> {
    let owner = env.pid();
    let sink = Arc::new(move |event: campy_renderer::sessions::Event| {
        let mut env = OwnedEnv::new();
        let _ = env.send_and_clear(&owner, |env| {
            (
                campy_event(),
                event.session,
                event.generation,
                event.kind,
                event.payload,
            )
                .encode(env)
        });
    });
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
    resource.session.submit(command.into())?;
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

#[cfg(feature = "ui-testing")]
#[derive(rustler::NifTaggedEnum)]
enum TestInput {
    Click(f32, f32),
    Text(String),
    KeyCombo(Vec<String>),
    Close,
}

#[cfg(feature = "ui-testing")]
#[rustler::nif]
fn test_input(
    env: Env,
    resource: ResourceArc<SessionResource>,
    generation: u64,
    input: TestInput,
) -> Result<rustler::Atom, String> {
    authorize(env, &resource)?;
    use campy_renderer::sessions::{Command as Native, TestInput as Input};
    let input = match input {
        TestInput::Click(x, y) => Input::Click(x, y),
        TestInput::Text(text) => Input::Text(text),
        TestInput::KeyCombo(keys) => Input::KeyCombo(keys),
        TestInput::Close => Input::Close,
    };
    resource
        .session
        .submit(Native::TestInput(generation, input))?;
    Ok(nil())
}

rustler::init!("campy_bridge_ffi");
