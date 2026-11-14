//! Minimal synchronous LSP client over stdio, hosting `gleam lsp` for the
//! handler-code editor. The protocol logic is hand-rolled (initialize,
//! didOpen/didChange full-sync, completion, publishDiagnostics) so the NIF
//! stays free of an async runtime; results travel to the session owner as
//! ordinary `campy_event` tuples (kind `lsp:completions` / `lsp:diagnostics`).

use crate::{campy_event, nil};
use rustler::{Encoder, Env, LocalPid, OwnedEnv, Resource, ResourceArc};
use std::io::{BufRead, BufReader, Read, Write};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::{Arc, Mutex};

pub struct LspResource {
    child: Mutex<Option<Child>>,
    writer: Arc<Mutex<Option<ChildStdin>>>,
    completion_id: AtomicI64,
}

#[rustler::resource_impl]
impl Resource for LspResource {}

impl Drop for LspResource {
    fn drop(&mut self) {
        stop(self);
    }
}

fn stop(resource: &LspResource) {
    if let Ok(mut guard) = resource.child.lock() {
        if let Some(child) = guard.as_mut() {
            let _ = child.kill();
            let _ = child.wait();
        }
        *guard = None;
    }
}

fn send_frame(writer: &Arc<Mutex<Option<ChildStdin>>>, body: &str) {
    if let Ok(mut guard) = writer.lock() {
        if let Some(stdin) = guard.as_mut() {
            let frame = format!("Content-Length: {}\r\n\r\n{}", body.len(), body);
            let _ = stdin.write_all(frame.as_bytes());
            let _ = stdin.flush();
        }
    }
}

fn notify(writer: &Arc<Mutex<Option<ChildStdin>>>, method: &str, params: serde_json::Value) {
    let body = serde_json::json!({"jsonrpc": "2.0", "method": method, "params": params});
    send_frame(writer, &body.to_string());
}

fn request(
    writer: &Arc<Mutex<Option<ChildStdin>>>,
    id: i64,
    method: &str,
    params: serde_json::Value,
) {
    let body = serde_json::json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
    send_frame(writer, &body.to_string());
}

// Field separator inside a completion line; labels never contain these.
const FIELD: char = '\t';
const ROW: char = '\n';

fn completion_kind(kind: Option<u64>) -> String {
    // LSP CompletionItemKind, reduced to the editor's vocabulary.
    match kind {
        Some(2) => "method".into(),
        Some(3) => "function".into(),
        Some(5) | Some(6) => "field".into(),
        Some(7) | Some(8) | Some(13) | Some(14) => "type".into(),
        Some(9) => "module".into(),
        Some(10) | Some(12) => "property".into(),
        Some(15) => "keyword".into(),
        Some(_) => "name".into(),
        None => "name".into(),
    }
}

fn clean(text: &str) -> String {
    text.replace(FIELD, " ").replace(ROW, " ")
}

fn completion_payload(items: &[serde_json::Value]) -> String {
    let mut rows = Vec::new();
    for item in items {
        let label = item.get("label").and_then(|v| v.as_str()).unwrap_or("");
        if label.is_empty() {
            continue;
        }
        let kind = completion_kind(item.get("kind").and_then(|v| v.as_u64()));
        let insert = item
            .get("insertText")
            .and_then(|v| v.as_str())
            .unwrap_or(label);
        let detail = item.get("detail").and_then(|v| v.as_str()).unwrap_or("");
        rows.push(format!(
            "{}{}{}{}{}{}{}",
            clean(label),
            FIELD,
            clean(detail),
            FIELD,
            clean(insert),
            FIELD,
            kind
        ));
    }
    rows.join(ROW.to_string().as_str())
}

fn diagnostics_payload(diagnostics: &[serde_json::Value]) -> String {
    let mut rows = Vec::new();
    for diagnostic in diagnostics {
        let line = diagnostic
            .get("range")
            .and_then(|range| range.get("start"))
            .and_then(|start| start.get("line"))
            .and_then(|v| v.as_u64())
            .unwrap_or(0);
        let severity = diagnostic
            .get("severity")
            .and_then(|v| v.as_u64())
            .unwrap_or(1);
        let message = diagnostic
            .get("message")
            .and_then(|v| v.as_str())
            .unwrap_or("");
        rows.push(format!(
            "{}{}{}{}{}",
            line,
            FIELD,
            severity,
            FIELD,
            clean(message)
        ));
    }
    rows.join(ROW.to_string().as_str())
}

fn forward(owner: LocalPid, kind: &str, payload: String) {
    let mut env = OwnedEnv::new();
    let _ = env.send_and_clear(&owner, |env| {
        (campy_event(), 0, 0, kind.to_string(), payload).encode(env)
    });
}

#[rustler::nif]
fn lsp_start(env: Env, root: String) -> Result<ResourceArc<LspResource>, String> {
    let owner = env.pid();
    let mut child = Command::new("gleam")
        .arg("lsp")
        .current_dir(&root)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|error| format!("Cannot start gleam lsp: {error}"))?;
    let stdin = child.stdin.take().ok_or("gleam lsp has no stdin")?;
    let stdout = child.stdout.take().ok_or("gleam lsp has no stdout")?;
    let writer = Arc::new(Mutex::new(Some(stdin)));
    let resource = ResourceArc::new(LspResource {
        child: Mutex::new(Some(child)),
        writer: writer.clone(),
        completion_id: AtomicI64::new(1000),
    });
    let reader_writer = writer.clone();
    let reader_owner = owner;
    std::thread::spawn(move || read_loop(reader_owner, reader_writer, stdout));
    // Initialize handshake; the reader sends `initialized` once the reply
    // arrives, before any other request the host may issue.
    request(
        &writer,
        1,
        "initialize",
        serde_json::json!({
            "processId": std::process::id(),
            "rootUri": format!("file://{}", root),
            "capabilities": {},
        }),
    );
    Ok(resource)
}

fn read_loop(
    owner: LocalPid,
    writer: Arc<Mutex<Option<ChildStdin>>>,
    stdout: std::process::ChildStdout,
) {
    let mut reader = BufReader::new(stdout);
    loop {
        let body = match read_frame(&mut reader) {
            Some(body) => body,
            None => return,
        };
        let Ok(message) = serde_json::from_str::<serde_json::Value>(&body) else {
            continue;
        };
        if let Some(method) = message.get("method").and_then(|v| v.as_str()) {
            match method {
                "textDocument/publishDiagnostics" => {
                    let diagnostics = message
                        .get("params")
                        .and_then(|params| params.get("diagnostics"))
                        .and_then(|value| value.as_array())
                        .cloned()
                        .unwrap_or_default();
                    forward(owner, "lsp:diagnostics", diagnostics_payload(&diagnostics));
                }
                _ => {}
            }
            continue;
        }
        // A response: id 1 is the initialize handshake (the reader already
        // sent `initialized`); completion requests are numbered from 1000.
        let Some(result) = message.get("result") else {
            continue;
        };
        let id = message.get("id").and_then(|v| v.as_i64()).unwrap_or(0);
        if id == 1 {
            notify(&writer, "initialized", serde_json::json!({}));
            forward(owner, "lsp:ready", String::new());
            continue;
        }
        if id < 1000 {
            continue;
        }
        let items = match result {
            serde_json::Value::Array(items) => items.clone(),
            serde_json::Value::Object(map) => map
                .get("items")
                .and_then(|value| value.as_array())
                .cloned()
                .unwrap_or_default(),
            _ => Vec::new(),
        };
        forward(owner, "lsp:completions", completion_payload(&items));
    }
}

fn read_frame(reader: &mut BufReader<ChildStdout>) -> Option<String> {
    let mut length: Option<usize> = None;
    loop {
        let mut line = String::new();
        let read = reader.read_line(&mut line).ok()?;
        if read == 0 {
            return None; // server closed
        }
        let line = line.trim_end();
        if line.is_empty() {
            break;
        }
        if let Some(value) = line.strip_prefix("Content-Length:") {
            length = value.trim().parse().ok();
        }
    }
    let length = length?;
    let mut body = vec![0u8; length];
    reader.read_exact(&mut body).ok()?;
    String::from_utf8(body).ok()
}

#[rustler::nif]
fn lsp_open(
    resource: ResourceArc<LspResource>,
    uri: String,
    text: String,
) -> Result<rustler::Atom, String> {
    notify(
        &resource.writer,
        "textDocument/didOpen",
        serde_json::json!({
            "textDocument": {
                "uri": uri, "languageId": "gleam", "version": 1, "text": text,
            }
        }),
    );
    Ok(nil())
}

#[rustler::nif]
fn lsp_change(
    resource: ResourceArc<LspResource>,
    uri: String,
    version: i64,
    text: String,
) -> Result<rustler::Atom, String> {
    notify(
        &resource.writer,
        "textDocument/didChange",
        serde_json::json!({
            "textDocument": {"uri": uri, "version": version},
            "contentChanges": [{"text": text}],
        }),
    );
    Ok(nil())
}

#[rustler::nif]
fn lsp_completions(
    resource: ResourceArc<LspResource>,
    uri: String,
    line: i64,
    character: i64,
) -> Result<rustler::Atom, String> {
    let id = resource.completion_id.fetch_add(1, Ordering::SeqCst);
    request(
        &resource.writer,
        id,
        "textDocument/completion",
        serde_json::json!({
            "textDocument": {"uri": uri},
            "position": {"line": line, "character": character},
        }),
    );
    Ok(nil())
}

#[rustler::nif]
fn lsp_stop(resource: ResourceArc<LspResource>) -> Result<rustler::Atom, String> {
    stop(&resource);
    Ok(nil())
}
