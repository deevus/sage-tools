# sage-tools

`sage-tools` is a Sage extension pack publishing focused tools such as `edit`, `rg`, `find_files`, and `find_references`.

Sage already provides native `read` and `write` tools, so this pack intentionally
focuses on exact-text editing.

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
2. **Ripgrep's own ignore rules** (`.gitignore`, `.ignore`, `.rgignore`) apply
   automatically. There are no sage-tools-level default excludes. Agents should
   pass `exclude_globs` / `include_globs` for project-specific noise control
   over directories like `node_modules`, `build` artifacts, or generated files.
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

## `find_references`

`find_references` finds exact text or identifier references in the active project
without exposing arbitrary regex input.

Schema:

- `identifier` (`string`, optional): exact text to find with fixed-string,
  word-boundary matching. Use this for simple identifiers.
- `text` (`string`, optional): exact literal text to find without word-boundary
  matching. Use this for punctuation-heavy member references like
  `ctx.pack.require`.
- Exactly one of `identifier` or `text` must be provided.
- `paths` (`array` of `string`, optional): project-relative files or directories
  to search. Defaults to the project root.
- `include_globs` / `exclude_globs` (`array` of `string`, optional): additional
  ripgrep glob patterns.
- `case_sensitive` (`boolean`, optional): when false, pass `--ignore-case`.
- `context_lines` (`integer`, optional): context lines before/after each match.
  Capped at 3.
- `max_results` (`integer`, optional): maximum rows to return. Capped at 500.
- `max_output_bytes` (`integer`, optional): maximum total bytes of row summaries.
  Capped at 65536.
- `timeout_ms` (`integer`, optional): ripgrep timeout. Capped at 10000 ms.
- `rg_executable` (`string`, optional): executable override for testing or custom
  PATH installs; path separators and traversal are rejected.

Behavior:

1. Searches are project-root confined. Path arguments must be project-relative;
   absolute paths and `..` traversal are rejected.
2. The tool follows `rg` exclude behavior: ripgrep's own ignore rules apply
   automatically, and sage-tools does not add default exclude globs. Use
   `exclude_globs` for caller-specific noise reduction.
3. Both modes use ripgrep fixed-string matching and reject empty or multiline
   queries. `identifier` also passes ripgrep `--word-regexp`.
4. Returns compact reference rows (`path`, `line`, `column`, `summary`, `kind`) in
   `details.rows` plus mode/query and truncation metadata in `details.meta`.
5. When there are no matches, rows is empty and the tool succeeds.

## `find_files`

`find_files` finds likely relevant project files by filename and/or content hints without dumping broad shell output.

Schema:

- `filename_hints` (`array` of `string`, optional): case-insensitive filename or path fragments.
- `content_hints` (`array` of `string`, optional): content patterns. Regex by default, literal when `fixed_strings` is true.
- `paths` (`array` of `string`, optional): project-relative files or directories to search. Defaults to the project root.
- `include_globs` / `exclude_globs` (`array` of `string`, optional): additional ripgrep glob patterns.
- `fixed_strings` (`boolean`, optional): treat content hints as literal text.
- `case_sensitive` (`boolean`, optional): when false, pass `--ignore-case` for content hints. Filename hint matching is always case-insensitive.
- `context_lines` (`integer`, optional): context lines before/after content matches. Capped at 3.
- `max_results` (`integer`, optional): maximum rows to return across filename and content matches. Capped at 500.
- `max_output_bytes` (`integer`, optional): maximum total bytes of row summaries. Capped at 65536.
- `timeout_ms` (`integer`, optional): ripgrep timeout. Capped at 10000 ms.
- `rg_executable` (`string`, optional): executable override for testing or custom PATH installs; path separators and traversal are rejected.

Behavior:

1. Searches are project-root confined. Path arguments must be project-relative; absolute paths and `..` traversal are rejected.
2. The tool follows `rg` exclude behavior: ripgrep's own ignore rules apply automatically, and sage-tools does not add default exclude globs. Use `exclude_globs` for caller-specific noise reduction.
3. Filename hints are matched case-insensitively against paths returned by `rg --files`.
4. Content hints are searched with ripgrep and return line/column metadata when available.
5. Result limits enforce shared caps on rows, context lines, output bytes, timeout, and summary width. Truncation metadata is reported in `details.meta`.
6. When there are no matches, rows is empty and the tool succeeds.

## Development layout

Shared Lua code lives under the pack-level `lua/` directory and is loaded from
member extensions and their tests with `ctx.pack.require(...)`. Keep reusable
runtime helpers in `lua/support/`; keep extension-specific tool logic inside the
member extension directories.

## Install

```sh
sage extensions install https://github.com/deevus/sage-tools.git
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
