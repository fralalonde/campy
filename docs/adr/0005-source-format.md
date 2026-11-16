# ADR 0005: source documents are canonical JSON text

Status: accepted.

## Context

The prototype stores projects and workspaces as compressed Erlang terms
(`projects/*.campy`). They are binary, unreadable, unmergeable, and currently
git-ignored, so form designs are not versioned at all. A form designer whose
output cannot be reviewed, diffed, blamed, or hand-fixed is a liability in a
team workflow. The planned JSON representation of views makes a text format the
natural choice rather than an extra one.

## Decision

### 1. Source is text; artifacts are binary

- Humans author and review: forms, handler code, project metadata, assets.
- Machines derive: beams, manifests, deployment state. These live under
  `generated/` and stay out of git.
- A future single-file `.campy` bundle is an export/import convenience, never
  the source of truth.

### 2. A project is a directory, and that directory is the repository

```
my-project/
  campy.json            # schema, title, module order
  modules/
    cat_cafe/
      form.json         # the view tree for this module
      handlers.gleam    # handler source
  assets/
```

There is no workspace file. "Recent projects" is local user configuration; the
project directory is the unit that is opened, committed, and shared.

### 3. Forms are canonical JSON

- A `form.json` is the serialized view tree (kind, id, key, props, events,
  children) plus a `schema` version.
- The writer is deterministic: fixed key order, props sorted by name, 2-space
  indent, LF endings, trailing newline, integers for coordinates, colors as
  `#rrggbb` strings, no timestamps or derived fields.
- Unknown fields survive a load/save round trip so an older IDE cannot silently
  destroy data written by a newer one.
- Tests enforce `load(save(x))` byte equality, save idempotence, and golden
  documents for the demo project; `just fmt-forms --check` catches drift in CI.

### 4. Identity is stable and separate from names

- Each node has a random short id. Ids never change on rename and are not
  derived from names, so branches that add controls do not collide and renaming
  a control is not a document-wide rewrite.
- A node's `name` is a property. Handler names derive from it; renaming is an
  explicit IDE refactor that updates the handler module.
- Sibling order is semantic: children array order is both layout order and
  z-order.

### 5. Versioned, validated loading

Each file carries `schema`. The loader runs the migration chain (the same
planner/executor used for artifacts) and saves in the current schema. Unknown
kinds or event keys are hard errors with a file path; unknown properties are
preserved with a warning; a file newer than the IDE refuses to open rather than
down-converting.

## Consequences

- `git diff` reviews a form change; `git blame` finds the edit; merge conflicts
  are localized to one module file.
- Compression and binary codecs leave the authoring path but remain available
  for artifacts and broker state.
- JSON has no comments. That is acceptable because the designer is the authoring
  surface; if annotations are needed, they belong in a property, not the format.
- Canonical output means any hand edit is normalized on the next save; CI
  enforces that the committed text is already canonical.
- The project/workspace codecs (v1–v11) are retired with the legacy IDE; the
  migration module survives as the general mechanism.
