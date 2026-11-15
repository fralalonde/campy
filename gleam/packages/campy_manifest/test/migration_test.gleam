import campy_manifest.{type Step, Step}
import campy_manifest/migration
import gleam/list
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

fn chain() -> List(Step) {
  [
    Step(9, 10, "control colors"),
    Step(10, 11, "property values"),
    Step(11, 12, "handlers take config"),
  ]
}

pub fn same_version_needs_no_steps_test() {
  migration.plan(11, 11, []) |> should.equal(Ok([]))
}

pub fn same_version_ignores_a_nonempty_chain_test() {
  migration.plan(11, 11, chain()) |> should.equal(Ok([]))
}

pub fn single_step_test() {
  migration.plan(9, 10, chain())
  |> should.equal(Ok([Step(9, 10, "control colors")]))
}

pub fn multi_step_test() {
  migration.plan(9, 12, chain()) |> should.equal(Ok(chain()))
}

pub fn mid_chain_start_skips_applied_steps_test() {
  migration.plan(11, 12, chain())
  |> should.equal(Ok([Step(11, 12, "handlers take config")]))
}

pub fn gap_is_an_error_test() {
  migration.plan(9, 12, [
    Step(9, 10, "control colors"),
    Step(11, 12, "handlers take config"),
  ])
  |> should.equal(Error("no migration path: 9 -> 12"))
}

pub fn missing_tail_is_an_error_test() {
  migration.plan(9, 12, [
    Step(9, 10, "control colors"),
    Step(10, 11, "property values"),
  ])
  |> should.equal(Error("no migration path: 9 -> 12"))
}

pub fn unknown_start_is_an_error_test() {
  migration.plan(8, 10, chain())
  |> should.equal(Error("no migration path: 8 -> 10"))
}

pub fn wrong_order_is_an_error_test() {
  migration.plan(9, 11, [
    Step(10, 11, "property values"),
    Step(9, 10, "control colors"),
  ])
  |> should.equal(Error("no migration path: 9 -> 11"))
}

pub fn backwards_target_is_an_error_test() {
  migration.plan(11, 9, chain())
  |> should.equal(Error("no migration path: 11 -> 9"))
}

pub fn cycle_is_an_error_test() {
  migration.plan(9, 13, [
    Step(9, 10, "control colors"),
    Step(10, 11, "property values"),
    Step(11, 10, "revert property values"),
    Step(10, 11, "property values again"),
  ])
  |> should.equal(Error("no migration path: 9 -> 13"))
}

pub fn overshooting_step_is_an_error_test() {
  migration.plan(9, 11, [Step(9, 12, "skips a version")])
  |> should.equal(Error("no migration path: 9 -> 11"))
}

pub fn run_passes_each_next_version_in_order_test() {
  migration.run([], chain(), fn(version, seen) { list.append(seen, [version]) })
  |> should.equal([10, 11, 12])
}

pub fn run_folds_state_through_steps_test() {
  migration.run(0, chain(), fn(version, total) { total * 100 + version })
  |> should.equal(101_112)
}

pub fn run_with_no_steps_returns_state_test() {
  migration.run("unchanged", [], fn(_, state) { state })
  |> should.equal("unchanged")
}

pub fn run_of_planned_steps_passes_exactly_from_plus_one_to_to_test() {
  let assert Ok(steps) = migration.plan(9, 12, chain())
  migration.run([], steps, fn(version, seen) { list.append(seen, [version]) })
  |> should.equal([10, 11, 12])
}

pub fn compatible_is_true_when_a_plan_exists_test() {
  migration.compatible(9, 12, chain()) |> should.be_true()
}

pub fn compatible_is_true_for_the_current_version_test() {
  migration.compatible(12, 12, chain()) |> should.be_true()
}

pub fn compatible_is_false_when_the_path_has_a_gap_test() {
  migration.compatible(9, 12, [Step(9, 10, "control colors")])
  |> should.be_false()
}

pub fn compatible_is_false_for_an_older_target_test() {
  migration.compatible(12, 9, chain()) |> should.be_false()
}
