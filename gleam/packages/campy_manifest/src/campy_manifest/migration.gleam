//// Migration chains: the version lattice between a runner's current state and
//// an artifact's target version.
////
//// These are pure functions over the migration steps recorded in a manifest.
//// They answer "can a runner at state version X accept an artifact at version
//// Y, and by which steps?" without knowing what any step's upgrade actually
//// does: the caller supplies the per-version upgrade function to `run`.
////
//// No concrete project-format upgrade lives here. This module is the planning
//// and mechanical execution seam only.

import campy_manifest.{type Step}
import gleam/int
import gleam/list
import gleam/result

/// Plans the migration from `from` to `to` over `chain`, returning the steps to
/// apply in order.
///
/// Steps already behind `from` (`step.to <= from`) are applied history and are
/// skipped; the rest must form one forward route that starts at `from` and ends
/// at `to`. A step may advance one or more versions, but every step must start
/// at the version the previous one reached. A missing link, a step out of
/// order, or a cycle is an error.
///
/// `from == to` is always `Ok([])`: no migration is required.
pub fn plan(
  from: Int,
  to: Int,
  chain: List(Step),
) -> Result(List(Step), String) {
  case from == to {
    True -> Ok([])
    False ->
      chain
      |> list.filter(fn(step) { step.to > from })
      |> walk(from, to, [from], [])
      |> result.replace_error(no_path(from, to))
  }
}

/// Folds `state` through `steps` in order, calling `up(step.to, state)` for each
/// step.
///
/// The caller owns the per-version upgrade logic; this is mechanical execution
/// only. Pair it with `plan` to know the steps are a valid route first.
pub fn run(state: a, steps: List(Step), up: fn(Int, a) -> a) -> a {
  list.fold(steps, state, fn(state, step) { up(step.to, state) })
}

/// Whether state version `current` can accept an artifact at `target` over
/// `chain`.
pub fn compatible(current: Int, target: Int, chain: List(Step)) -> Bool {
  plan(current, target, chain) |> result.is_ok
}

fn walk(
  steps: List(Step),
  current: Int,
  target: Int,
  visited: List(Int),
  applied: List(Step),
) -> Result(List(Step), Nil) {
  case current == target {
    True -> Ok(list.reverse(applied))
    False ->
      case steps {
        [] -> Error(Nil)
        [step, ..rest] ->
          case step.from == current && step.to > step.from {
            False -> Error(Nil)
            True ->
              case list.contains(visited, step.to) {
                True -> Error(Nil)
                False ->
                  walk(rest, step.to, target, [step.to, ..visited], [
                    step,
                    ..applied
                  ])
              }
          }
      }
  }
}

fn no_path(from: Int, to: Int) -> String {
  "no migration path: " <> int.to_string(from) <> " -> " <> int.to_string(to)
}
