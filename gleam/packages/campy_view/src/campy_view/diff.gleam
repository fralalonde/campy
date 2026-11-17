//// Structural diff between two view trees.
////
//// Children are matched by identity (key, else id), so an inserted control
//// costs one `Insert`, a property edit costs one `SetProps`, and a reorder
//// costs one `Order`. A matched identity with a new id is a `Replace`: the
//// renderer remounts that subtree rather than mutating widget identity.
////
//// Patches are ordered removals, per-child updates and inserts (in target
//// order), then at most one `Order`. Applying a batch is therefore safe in
//// sequence, and the trailing `Order` is authoritative.

import campy_view.{
  type Node, type Patch, Insert, Order, Remove, Replace, SetEvents, SetProps,
}
import gleam/dict
import gleam/list

pub fn diff(previous: Node, next: Node) -> List(Patch) {
  let previous = campy_view.normalize(previous)
  let next = campy_view.normalize(next)

  case
    campy_view.identity(previous) == campy_view.identity(next),
    previous.id == next.id,
    previous.kind == next.kind
  {
    True, True, True -> removals_first(diff_node(previous, next))
    _, _, _ -> [Replace(previous.id, next)]
  }
}

fn removals_first(patches: List(Patch)) -> List(Patch) {
  let removals =
    list.filter(patches, fn(patch) {
      case patch {
        Remove(_) -> True
        _ -> False
      }
    })
  let rest =
    list.filter(patches, fn(patch) {
      case patch {
        Remove(_) -> False
        _ -> True
      }
    })

  list.append(removals, rest)
}

fn diff_node(previous: Node, next: Node) -> List(Patch) {
  let prop_patches = case previous.props == next.props {
    True -> []
    False -> [SetProps(next.id, next.props)]
  }

  let event_patches = case previous.events == next.events {
    True -> []
    False -> [SetEvents(next.id, next.events)]
  }

  list.append(
    list.append(prop_patches, event_patches),
    diff_children(previous.id, previous.children, next.children),
  )
}

fn diff_children(
  parent: String,
  previous: List(Node),
  next: List(Node),
) -> List(Patch) {
  case previous, next {
    [], [] -> []
    _, _ -> {
      let old_by_identity =
        list.fold(previous, dict.new(), fn(acc, child) {
          dict.insert(acc, campy_view.identity(child), child)
        })
      let next_identities = list.map(next, campy_view.identity)

      let removals =
        previous
        |> list.filter(fn(child) {
          !list.contains(next_identities, campy_view.identity(child))
        })
        |> list.map(fn(child) { Remove(child.id) })

      let updates =
        next
        |> list.index_map(fn(child, index) {
          case dict.get(old_by_identity, campy_view.identity(child)) {
            Error(Nil) -> [Insert(parent, index, child)]
            Ok(old_child) ->
              case old_child.id == child.id && old_child.kind == child.kind {
                True -> diff_node(old_child, child)
                False -> [Replace(old_child.id, child)]
              }
          }
        })
        |> list.flatten

      let survivors_before =
        previous
        |> list.filter(fn(child) {
          list.contains(next_identities, campy_view.identity(child))
        })
        |> list.map(fn(child) { child.id })

      let survivors_after =
        next
        |> list.filter(fn(child) {
          case dict.get(old_by_identity, campy_view.identity(child)) {
            Ok(old_child) ->
              old_child.id == child.id && old_child.kind == child.kind
            Error(Nil) -> False
          }
        })
        |> list.map(fn(child) { child.id })

      let patches = list.append(removals, updates)

      case survivors_before != survivors_after {
        True ->
          list.append(patches, [
            Order(parent, list.map(next, fn(child) { child.id })),
          ])
        False -> patches
      }
    }
  }
}
