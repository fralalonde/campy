import campy_app
import campy_app/handler
import campy_bridge
import campy_form
import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

// The bridge needs a real display server. Pure tests always run; the session
// tier skips automatically in headless CI.
@external(erlang, "campy_app_ffi", "has_display")
fn has_display() -> Bool

fn fixture_form() -> campy_form.Form {
  campy_form.Form(
    "campy.form",
    "Handler fixture",
    640,
    420,
    campy_form.Free,
    [
      control("pet-button", "pet_button"),
      control("break-button", "break_button"),
      control("long-button", "long_button"),
      control("missing-button", "missing_button"),
      // The two naming conventions the spec fix had to preserve: ids with a
      // hyphen before a digit map to names without the hyphen, while ids with
      // interior hyphens map to snake_case names.
      control("button-1", "button1"),
      control("search-edit", "search_edit"),
    ],
    [],
    [],
    [],
    [],
    [],
    [],
  )
}

fn form_with_title(title: String) -> campy_form.Form {
  let form = fixture_form()
  campy_form.Form(..form, title: title)
}

fn control(id: String, name: String) -> campy_form.Control {
  campy_form.Control(
    id,
    name,
    campy_form.Button,
    0,
    0,
    100,
    32,
    "Button",
    True,
    True,
    [],
  )
}

// --- Pure tier: handler FFI, dispatch mapping, report rendering -------------

pub fn apply_handler_ok_test() {
  handler.apply_handler("campy_app_fixture_handlers", "pet_button_clicked")
  |> should.equal(Ok(Nil))
}

pub fn apply_handler_raising_test() {
  let assert Error(reason) =
    handler.apply_handler("campy_app_fixture_handlers", "break_button_clicked")
  string.contains(reason, "boom") |> should.be_true
}

pub fn apply_handler_missing_test() {
  handler.apply_handler("campy_app_fixture_handlers", "no_such_handler")
  |> should.equal(Error("no handler"))
}

pub fn apply_handler_unknown_module_test() {
  handler.apply_handler("campy_app_no_such_fixture", "anything")
  |> should.equal(Error("no handler"))
}

pub fn handler_name_mapping_test() {
  let form = fixture_form()
  handler.name_for(form, "pet-button", "clicked")
  |> should.equal(Some("pet_button_clicked"))
  handler.name_for(form, "button-1", "clicked")
  |> should.equal(Some("button1_clicked"))
  handler.name_for(form, "search-edit", "changed")
  |> should.equal(Some("search_edit_changed"))
  handler.name_for(form, "not-a-control", "clicked")
  |> should.equal(None)
}

pub fn handler_run_ok_test() {
  handler.run(
    fixture_form(),
    "campy_app_fixture_handlers",
    "pet-button",
    "clicked",
  )
  |> should.equal(Ok(Nil))
}

pub fn handler_run_raising_test() {
  let assert Error(reason) =
    handler.run(
      fixture_form(),
      "campy_app_fixture_handlers",
      "break-button",
      "clicked",
    )
  string.contains(reason, "boom") |> should.be_true
}

pub fn handler_run_missing_test() {
  handler.run(
    fixture_form(),
    "campy_app_fixture_handlers",
    "missing-button",
    "clicked",
  )
  |> should.equal(Error("no handler"))
}

pub fn handler_run_unknown_control_test() {
  handler.run(fixture_form(), "campy_app_fixture_handlers", "nope", "clicked")
  |> should.equal(Error("no handler"))
}

pub fn handler_reason_truncation_test() {
  handler.truncate("first line\nsecond line")
  |> should.equal("first line")
  handler.truncate(string.repeat("x", 300))
  |> string.length
  |> should.equal(180)
  let long_reason =
    handler.run(
      fixture_form(),
      "campy_app_fixture_handlers",
      "long-button",
      "clicked",
    )
    |> result_error_reason
    |> handler.truncate
  let long_reason_fits = string.length(long_reason) <= 180
  long_reason_fits |> should.be_true
}

fn result_error_reason(result: Result(Nil, String)) -> String {
  let assert Error(reason) = result
  reason
}

pub fn report_text_rendering_test() {
  campy_app.report_text(campy_app.Started("cat_cafe", 3, "abc123"))
  |> should.equal("started v3")
  campy_app.report_text(campy_app.Applied("cat_cafe"))
  |> should.equal("applied")
  campy_app.report_text(campy_app.CodeUpdated("cat_cafe", 4))
  |> should.equal("code-updated v4")
  campy_app.report_text(campy_app.HandlerError(
    "pet_button_clicked",
    "error:boom",
  ))
  |> should.equal("handler error: pet_button_clicked: error:boom")
  campy_app.report_text(campy_app.Restarted("cat_cafe", "killed"))
  |> should.equal("restarted: killed")
  campy_app.report_text(campy_app.GaveUp("cat_cafe", "shutdown"))
  |> should.equal("gave up: shutdown")
  campy_app.report_text(campy_app.Stopped("cat_cafe"))
  |> should.equal("stopped")
  campy_app.report_text(campy_app.Console("raw line"))
  |> should.equal("raw line")
}

pub fn report_line_rendering_test() {
  campy_app.report_line("cat_cafe", campy_app.Started("cat_cafe", 1, "abc"))
  |> should.equal("[cat_cafe] started v1")
  campy_app.report_line("cat_cafe", campy_app.Console("raw line"))
  |> should.equal("[cat_cafe] raw line")
}

// --- Session-dependent tier ------------------------------------------------

pub fn session_lifecycle_test() {
  case has_display() {
    False -> Nil
    True -> session_lifecycle()
  }
}

fn session_lifecycle() -> Nil {
  let reports = process.new_subject()
  let assert Ok(ref) =
    campy_app.start(
      campy_app.default_config(
        app: "cat_cafe",
        version: 1,
        digest: "digest-1",
        handlers_module: "campy_app_fixture_handlers",
        form: fixture_form(),
        report: fn(report) { process.send(reports, report) },
      ),
    )

  await_report(reports, fn(report) {
    case report {
      campy_app.Started("cat_cafe", 1, "digest-1") -> True
      _ -> False
    }
  })

  await_report(reports, fn(report) {
    case report {
      campy_app.Applied("cat_cafe") -> True
      _ -> False
    }
  })

  // A working handler is silent; the raising handler must be contained and
  // reported, not restart the actor.
  campy_app.deliver(
    ref,
    campy_bridge.NativeEvent(1, 1, "callback:event", "pet-button:clicked"),
  )
  campy_app.deliver(
    ref,
    campy_bridge.NativeEvent(1, 1, "callback:event", "break-button:clicked"),
  )
  let assert campy_app.HandlerError(handler_name, reason) =
    await_report(reports, fn(report) {
      case report {
        campy_app.HandlerError(_, _) -> True
        _ -> False
      }
    })
  handler_name |> should.equal("break_button_clicked")
  string.starts_with(reason, "error:") |> should.be_true
  string.contains(reason, "\n") |> should.be_false

  campy_app.deliver(
    ref,
    campy_bridge.NativeEvent(1, 1, "callback:event", "missing-button:clicked"),
  )
  let assert campy_app.HandlerError("missing_button_clicked", "no handler") =
    await_report(reports, fn(report) {
      case report {
        campy_app.HandlerError(_, _) -> True
        _ -> False
      }
    })

  // The app still works after the handler errors: a new snapshot applies.
  campy_app.apply_snapshot(ref, form_with_title("Handler fixture v2"))
  await_report(reports, fn(report) {
    case report {
      campy_app.Applied("cat_cafe") -> True
      _ -> False
    }
  })

  campy_app.stop(ref)
  let assert campy_app.Stopped("cat_cafe") =
    await_report(reports, fn(report) {
      case report {
        campy_app.Stopped("cat_cafe") -> True
        _ -> False
      }
    })
  Nil
}

fn await_report(
  reports: process.Subject(campy_app.Report),
  predicate: fn(campy_app.Report) -> Bool,
) -> campy_app.Report {
  case process.receive(reports, 10_000) {
    Ok(report) ->
      case predicate(report) {
        True -> report
        False -> await_report(reports, predicate)
      }
    Error(Nil) -> panic as "timed out waiting for a campy_app report"
  }
}
