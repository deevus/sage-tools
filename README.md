# sage-tools

`sage-tools` is a Sage extension pack. For now it publishes one tool: `edit`.

Sage already provides native `read` and `write` tools, so this pack intentionally
focuses on exact-text editing.

## Layout

```text
sage-tools/
  pack.zon
  edit/
    manifest.zon
    main.lua
    tests/edit.lua
```

## `edit`

`edit` applies one or more exact-text replacements to a single project file.

Schema:

- `path` (`string`, required): file path to edit. Relative, parent-relative,
  and absolute paths are allowed.
- `edits` (`array`, required): one or more replacements.
  - `old_text` (`string`, required): exact text that must occur once in the
    original file.
  - `new_text` (`string`, required): replacement text.

Behavior:

1. Read the original file.
2. Validate every edit before writing anything.
3. Fail without changing the file if any `old_text` is empty, missing,
   ambiguous, or overlaps another edit.
4. Apply all replacements to the original content.
5. Write through a same-directory temporary file and atomic rename.
6. Return a unified diff for the file.

This tool targets one file per call. For multiple files, call `edit` once per
file so each file has its own atomic write boundary. Paths are intentionally not
constrained to the project root; use exact `old_text` context to avoid editing
the wrong file.

## Install

```sh
sage extensions install ssh://git@forgejo.tail9a847c.ts.net/sh/sage-tools.git
```

## Test

From a Sage source checkout:

```sh
zig build run -- extensions test /path/to/sage-tools/edit
```

With an installed `sage` binary:

```sh
sage extensions test /path/to/sage-tools/edit
```
