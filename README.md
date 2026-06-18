# sage-tools

`sage-tools` is a Sage extension pack. For now it publishes two tools: `edit` and `rg`.

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
  rg/
    manifest.zon
    main.lua
    tests/rg.lua
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

## `rg`

`rg` searches the active project with ripgrep and returns compact, limited match
rows. It is the raw ripgrep escape hatch for unsupported patterns.

Schema:

- `pattern` (`string`, required): search pattern (regex by default, literal when
  `fixed_strings` is true).
- `paths` (`array` of `string`, optional): project-relative files or directories
  to search. Defaults to the project root.
- `include_globs` / `exclude_globs` (`array` of `string`, optional): additional
  ripgrep glob patterns.
- `fixed_strings` (`boolean`, optional): treat pattern as literal text.
- `case_sensitive` (`boolean`, optional): when false, pass `--ignore-case`.
- `context_lines` (`integer`, optional): context lines before/after each match.
  Capped at 3.
- `max_results` (`integer`, optional): maximum rows to return. Capped at 500.
- `max_output_bytes` (`integer`, optional): maximum total bytes of row summaries.
  Capped at 65536.
- `timeout_ms` (`integer`, optional): ripgrep timeout. Capped at 10000.
- `rg_executable` (`string`, optional): executable override for testing or custom
  PATH installs; path separators and traversal are rejected.

Behavior:

1. The search is **project-root confined**. Path arguments must be project-relative;
   absolute paths and `..` traversal are rejected.
2. **Default excludes** are applied to dependency, generated, and cache directories:
   `.git`, `.jj`, `.zig-cache`, `zig-out`, `node_modules`, `vendor`, `dist`,
   `build`, `coverage`, `target`, `.next`, `.cache`.
3. **Result limits** enforce caps on total rows (500), context lines (3), output
   bytes (65536), timeout (10000 ms), and per-line column width (240 chars).
   When any limit is hit, `details.meta` reports truncation metadata.
4. **Ripgrep is required.** If `rg` is not found, the tool raises an actionable
   error with install guidance for macOS (`brew install ripgrep`), Debian/Ubuntu
   (`apt install ripgrep`), and Arch Linux (`pacman -S ripgrep`). There is no
   fallback to grep or Lua-based file scanning.
5. Returns compact match rows (`path`, `line`, `column`, `summary`, `kind`) in
   `details.rows` and metadata in `details.meta`. When there are no matches,
   rows is empty and the tool succeeds.

## Install

```sh
sage extensions install ssh://git@forgejo.tail9a847c.ts.net/sh/sage-tools.git
```

## Test

From a Sage source checkout:

```sh
zig build run -- extensions test /path/to/sage-tools/edit
zig build run -- extensions test /path/to/sage-tools/rg
```

With an installed `sage` binary:

```sh
sage extensions test /path/to/sage-tools/edit
sage extensions test /path/to/sage-tools/rg
```
