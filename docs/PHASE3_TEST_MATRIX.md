# Phase 3 End-to-End Test Matrix

Manual regression suite for the bd-backed write path. Run through before
cutting any NppBeads release that touches CRUD code.

Each check is **pass** only if the observed state matches "Expected"
**and** the Console.app log line agrees (filter: `NppBeads`). Optimistic
UI moves don't count on their own — verify the underlying bd state.

## 1. Backend probe + fallback

| # | Scenario                                         | Expected                                                                                                                   |
|---|--------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------|
| 1.1 | Open a project with `.beads/` and `bd` installed | Status bar: `<proj> · N issues (o/b/c) · bd v1.0.2`. Probe log: `bd version → ok`, `bd info → ok`. Writes enabled.       |
| 1.2 | Open a project with `.beads/` but `bd` **not** in PATH | Status bar ends with `· read-only (JSONL)`. Drag shows toast `Install 'bd' to enable editing`. No bd log lines.       |
| 1.3 | Open a non-beads folder (no `.beads/`)           | Status bar: `no project · open a file inside a repo containing .beads/`. No panel actions available.                        |
| 1.4 | Cold probe latency (fresh project, no auth)      | `bd info` completes in under 1s (all calls now pass `--sandbox`). If it's > 5s, the sandbox flag got dropped — regression. |

## 2. Drag-and-drop status changes (Raw mode)

| # | Scenario                                                 | Expected                                                                                                                     |
|---|----------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------|
| 2.1 | Drag Closed → Open                                       | bd log: `bd update <id> --status open --json → ok`. JSONL shows new status. Toast: `<id> → Open`. Status-bar counts shift. |
| 2.2 | Drag Open → In Progress                                  | Same, `--status in_progress`. Toast: `<id> → In Progress`.                                                                    |
| 2.3 | Drag any → Blocked (manual blocked)                      | bd accepts `--status blocked`. Card stays in Blocked after refresh regardless of dep graph.                                  |
| 2.4 | Drag Closed → Open for issue with open blockers (in Effective mode) | bd update succeeds, but on refresh the card snaps back to Blocked. Toast: `<id> · shown in Blocked (has open blockers)`.   |
| 2.5 | Drag onto its own column                                 | No bridge call, no bd log. Cursor leaves normally.                                                                           |

## 3. Create issue

| # | Scenario                                                  | Expected                                                                                                                     |
|---|-----------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------|
| 3.1 | Title only, defaults                                      | `bd create "<title>" -t task -p 2 --json → ok`. Toast: `bd-XXX created`. New card appears in Open after refresh.            |
| 3.2 | Title empty                                               | Inline error `Title is required`. No bridge call. Modal stays open.                                                          |
| 3.3 | Title + type=bug + P0 + labels                            | Command includes `-t bug -p 0 -l backend -l api`. Labels visible on card. Priority P0 badge.                                 |
| 3.4 | Description with newlines and special chars (`$"\\`)      | bd log shows `--body-file=-`; stdin carries the text. Created bead's description matches exactly (open in detail modal).     |
| 3.5 | With 1 "Blocked by" chip                                  | After create: `bd dep add <newId> <chip> --type blocks → ok`. `bd show <newId>` lists the dep.                             |
| 3.6 | With 1 "Blocks" chip                                      | `bd dep add <chip> <newId> --type blocks → ok`. `bd show <chip>` now lists newId as a blocker.                             |
| 3.7 | With 2 "Blocked by" + 2 "Blocks" (four total)             | Four sequential depAdd log lines in order (blocked-by first, then blocks). Toast: `created with 4 deps`.                     |
| 3.8 | Blocker chip with non-existent id                         | Toast: `<newId> created; some deps failed: bd-nope (…)`. Issue itself was created.                                          |
| 3.9 | Cancel button                                             | Modal closes. No bd log line. No new issue.                                                                                  |

## 4. Detail modal — editing

Click any card to open the edit modal, then:

| # | Scenario                                        | Expected                                                                                                                       |
|---|-------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------|
| 4.1 | Change nothing → Save                           | Inline text: `no changes`. No bridge call.                                                                                     |
| 4.2 | Change title only                               | `bd update <id> --title "<new>" --json → ok`. No other flags in the argv.                                                    |
| 4.3 | Change status only                              | `bd update <id> --status <new> --json → ok`.                                                                                  |
| 4.4 | Change description with newlines                | argv contains `--description-file=-`. stdin has the new text.                                                                  |
| 4.5 | Change priority + labels (add `foo`, remove `bar`) | argv: `--priority 1 --add-label foo --remove-label bar`.                                                                     |
| 4.6 | Change assignee from `alice` to `bob`           | argv: `--assignee bob`.                                                                                                        |
| 4.7 | Clear assignee (field emptied)                  | Known limitation — assignee stays set. TODO: wire `--unassign`. Toast would claim ok, but `bd show` still shows old assignee.  |

## 5. Detail modal — actions

| # | Scenario                                        | Expected                                                                                                                       |
|---|-------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------|
| 5.1 | Click Claim                                     | `bd update <id> --claim --json → ok`. Toast: `<id> claimed`. `bd show` shows assignee = BEADS_ACTOR (NppBeads/$USER).       |
| 5.2 | Click Close (no open blockers)                  | `bd close <id> --json → ok`. Toast: `<id> closed`.                                                                            |
| 5.3 | Click Close (with open blockers)                | bd returns BlockedByDeps (errorKind=3). confirm() shows blocker ids. Cancel: no retry. Accept: retries with `--force`.        |
| 5.4 | Click Reopen (on a closed issue)                | `bd reopen <id> --json → ok`. Toast: `<id> reopened`. Button label switches to `Close` on next open of modal.                |
| 5.5 | Cancel → modal closes without writes            | No bridge call.                                                                                                                |

## 6. Search

| # | Scenario                                        | Expected                                                                                                                        |
|---|-------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------|
| 6.1 | Type a substring of an existing id              | Board columns filter; `col-count` shows `matched/total`.                                                                        |
| 6.2 | Type an unmatched string                        | Each column shows `no match (N filtered)` placeholder.                                                                          |
| 6.3 | Clear search                                    | All cards reappear. Counts revert to raw totals.                                                                                |

## 7. Raw / Effective toggle

| # | Scenario                                        | Expected                                                                                                                         |
|---|-------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------|
| 7.1 | Raw mode (default)                              | Cards grouped by stored `status` field. No dep-graph reasoning.                                                                  |
| 7.2 | Flip to Effective; issue with open blocker      | Card promotes from Open → Blocked column.                                                                                         |
| 7.3 | Effective mode; close the blocker               | After refresh, dependent card drops back to Open.                                                                                 |
| 7.4 | Effective mode; drag a blocked issue to Open    | bd update status=open succeeds. On refresh, card snaps to Blocked with toast `(has open blockers)`.                              |
| 7.5 | Reload the page                                 | Mode persists (localStorage key `nppbeads.board.statusMode`).                                                                     |

## 8. Error surfacing

| # | Scenario                                        | Expected                                                                                                                         |
|---|-------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------|
| 8.1 | bd command dies (e.g. delete `.beads/` between probe and drag) | Toast with stderr-first-real-line; error isn't the permissions Warning.                                                       |
| 8.2 | Invalid status value (JS bug)                   | bd returns `{"error":"invalid status"}` on stdout; toast shows that, not the permissions Warning.                               |
| 8.3 | Bridge timeout (15s with no response)           | Toast: `<id> · bridge timeout (updateBead)`. Optimistic state rolls back.                                                       |
| 8.4 | Stale optimistic after success                  | After `_broadcastDataChanged`, `App.onRefresh` clears the override map; no stale cards survive.                                 |

## 9. Interaction with external changes

| # | Scenario                                                                          | Expected                                                                                                                  |
|---|-----------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------|
| 9.1 | Terminal: `bd update ... --status in_progress`. Wait for watcher fire.            | Board re-renders card into In Progress within 1s (file watcher + `reloadData`).                                           |
| 9.2 | Terminal: add a dep. Effective mode on.                                           | Dependent card moves to Blocked on next refresh.                                                                          |
| 9.3 | External editor rewrites `.beads/issues.jsonl` out-of-band                         | Watcher fires. UI reflects new data. No crash if JSONL is mid-write (partial line tolerated — parse errors skipped).     |

---

## Known Phase-3 caveats

- **Clear-assignee not supported.** Emptying the assignee field is a no-op (bd needs `--unassign` which we don't wire yet).
- **Only `blocks` dep type exposed.** `tracks`, `related`, `parent-child`, etc. require the CLI for now.
- **No inline dep editor on existing issues.** Creation-time only; post-hoc dep changes need `bd dep add|remove` from a terminal.
- **Delete action absent.** Use `bd delete <id>` manually; add a UI button in Phase 3.5.
- **--sandbox is always on.** bd won't auto-push to git. Run `bd sync` from a terminal (or disable --sandbox in a future setting) to replicate to the origin.
