# Subagent Extension Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the issue #2 `subagent` pack member with a blocking read-only scout child Sage run.

**Architecture:** Add a reusable `lua/support/subagent.lua` helper that owns prompt temp-output creation, child Sage argv construction, structured JSONL parsing, and result shaping. Add `subagent/main.lua` as the model-callable wrapper and `subagent/tests/subagent.lua` with fake child executables for deterministic tests.

**Tech Stack:** Sage Lua extensions, `sage.execute`, `ctx.temp_output.create`, `sage extensions test`, shell-script fake child processes.

## Global Constraints

- Use Sage's resolved temp-output API: `ctx.temp_output.create/read` and `sage.test.temp_output.*`; do not use `ctx.call_tool`.
- Default child behavior is a blocking read-only scout with `--allow-tool read` and `--no-extensions`.
- Child prompt and system prompt must be written to files before invoking child Sage.
- Child invocation must include `--structured-output`.
- The model-visible result is compact: run summary plus final child answer.
- Details include child outcome, tool counts, failure info, and full-output temp URI or inline fallback.
- Tests run from Sage main with: `cd /tmp/sage-main-for-sage-tools && mise exec -- zig build run -- extensions test /Users/sh/Projects/sage-tools/.worktrees/issue-2-subagent/subagent`.

---

### Task 1: Subagent helper and tests

**Files:**
- Create: `lua/support/subagent.lua`
- Create: `subagent/tests/subagent.lua`

**Interfaces:**
- Produces `support.subagent.run(callback_ctx)` returning `{ content = string, details = table }`.
- Produces helper parsing/build functions for tests: `_parse_jsonl_events`, `_build_child_argv`, `_default_system_prompt`.

**Steps:**
- [ ] Write failing tests for schema-independent helper behavior through the `subagent` tool: success, failure, debug/full-output, default scout policy, and overrides.
- [ ] Run the subagent extension test and verify it fails because the extension/tool does not exist.
- [ ] Implement minimal helper functions and tool wrapper to pass tests.
- [ ] Run the subagent extension test and verify it passes.

### Task 2: Pack registration and docs

**Files:**
- Modify: `pack.zon`
- Create: `subagent/manifest.zon`
- Create: `subagent/main.lua`
- Modify: `README.md`

**Interfaces:**
- Pack member name: `subagent`.
- Tool name: `subagent`.
- Schema: top-level `task`, `label`, `system_prompt`; nested `child`, `debug`.

**Steps:**
- [ ] Write/extend tests asserting the registered schema shape.
- [ ] Add pack member and manifest/tool registration.
- [ ] Document tool schema, defaults, blockers/resolution, and v1 limitations.
- [ ] Run all extension tests for `edit`, `rg`, and `subagent` using Sage main.
