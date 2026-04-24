# Phase 3.5 End-to-End Test Matrix

Manual regression for the Phase 3.5 deliverables: dep editor on
existing-issue detail modal, delete-issue action, `--unassign` wiring,
full dep-type picker (10 types), and the per-project `--sandbox` toggle.

Each check is **pass** only if the observed state matches "Expected"
**and** the Console.app log line agrees (filter: `NppBeads`). Optimistic
UI moves don't count on their own — verify the underlying bd state via
`bd show <id> --json` in a terminal or the next panel refresh.

Pre-req for every section: a writable project (status bar shows
`bd vX.Y.Z` backend, not `read-only (JSONL)`).

## 1. Dep editor — existing-issue detail modal

| #    | Scenario                                                                    | Expected                                                                                                                        |
|------|-----------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------|
| 1.1  | Open a bead with no deps                                                    | "Dependencies" section shows **Blocked by** and **Blocks** headers, each with "none" placeholder and an add-row.               |
| 1.2  | Open a bead with 1 blocker (bd-XXX blocks bd-YYY; open bd-YYY)              | Under Blocked by: chip `bd-XXX` with × button. Add-row below. Blocks section shows "none".                                      |
| 1.3  | Open a bead that is in turn a blocker                                        | Blocks section lists the dependents. Blocked by shows its own.                                                                    |
| 1.4  | Existing dep with non-`blocks` type (e.g. `parent-child`)                    | Chip shows a small type-tag pill reading "parent-child" next to the id. Tooltip: "... · type: parent-child".                   |
| 1.5  | Click × on an existing dep chip                                              | Log: `_handleDepRemove` + `bd dep remove ... → ok`. Chip vanishes. Section re-renders from fresh App.beads. Board too.           |
| 1.6  | Add a new blocker (type default = blocks)                                    | Log: `bd dep add <beadId> <chipId> --type blocks`. Chip appears in Blocked by. Board's dep-count reflects.                      |
| 1.7  | Add a new dep with type = parent-child                                       | Same, `--type parent-child`. Chip shows a type-tag.                                                                              |
| 1.8  | Add a dep under "Blocks" group                                               | Direction flips: dependent=the NEW chip id, dependency=current bead. Chip appears in Blocks section.                           |
| 1.9  | Try to add the current bead as its own dep                                   | Inline error in status line: "An issue cannot depend on itself." No bridge call fires.                                        |
| 1.10 | Add a dep then immediately click × on it                                     | Both operations succeed serially. Chip add, then chip remove. No overlap / no deadlock.                                       |
| 1.11 | Add a non-existent id (e.g. `bd-zzzz`)                                       | Status line: bd's error ("issue not found" or similar). Chip does not appear. Add-row re-enables.                              |
| 1.12 | Add a dep that would create a cycle (A blocks B, then try A blocked-by B)    | Status line: bd's cycle error. Chip does not appear.                                                                            |
| 1.13 | Close the modal mid-dep-op                                                  | In-flight op completes; next open of the modal reflects the new state. No zombie spinner.                                      |
| 1.14 | Click on an existing dep chip's id link                                      | Current modal closes, new modal opens on that bead. Navigation via `#/issue/...` route.                                        |
| 1.15 | Dep section auto-refresh                                                    | After a successful add/remove, the section rebuilds in place (Board ALSO refreshes via _broadcastDataChanged). Chip count updates. |

## 2. Delete-issue

| #   | Scenario                                                                       | Expected                                                                                                                           |
|-----|--------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------|
| 2.1 | Open detail modal → red "Delete" button visible between Claim and Cancel       | Button present, styled .btn-danger (muted text, red on hover).                                                                      |
| 2.2 | Click Delete, confirm "OK"                                                     | Log: `deleteBead id=bd-XXX` + `bd delete bd-XXX --force --json → ok`. Toast: `bd-XXX deleted`. Modal closes. Card gone from Board.   |
| 2.3 | Click Delete, Cancel in confirm dialog                                         | No-op. No bridge call. No Console log. Button re-enables.                                                                           |
| 2.4 | Delete a bead that 2+ other beads depend on (dep-sweep warning)                | Confirm dialog lists the dependent ids (up to 8) with "⚠ N issues depend on this: ... Their dependency edges will be dropped."      |
| 2.5 | Delete a bead that >8 other beads depend on                                    | Confirm dialog shows first 8 + "…". Ellipsis after the last visible.                                                                |
| 2.6 | Delete a bead whose id no longer exists (race with external delete)            | bd errors with "not found". Status line shows error. Modal stays open.                                                             |
| 2.7 | Delete on JSONL-only backend (no bd)                                           | Delete button still visible but click → status line: "bd not installed" or similar ReadOnly error.                                 |
| 2.8 | Dependent chip count updates on the other beads                                | After delete, open a bead that was dependent on the deleted one — that chip is gone from its Dependencies section.                |

## 3. Unassign — empty-assignee submit

| #   | Scenario                                                                     | Expected                                                                                                                         |
|-----|------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------|
| 3.1 | Open a bead with assignee="alice", clear the field, click Save               | Log: `unassignBead id=bd-XXX` + `bd update bd-XXX --unassign --json → ok`. No updateBead follows (nothing else changed). Toast "updated". |
| 3.2 | Bead with no assignee; save without touching it                              | "no changes" in status line. No bridge call fires.                                                                               |
| 3.3 | Bead with assignee="alice"; change to "bob" and save                         | Regular updateBead flow with `--assignee bob`. No unassign call.                                                                 |
| 3.4 | Bead with assignee="alice"; clear it AND also change the title               | Unassign fires FIRST, then updateBead with only title change. Both succeed or the modal shows the failed one's error.            |
| 3.5 | Unassign on a bead that has no assignee set                                  | bd may return a warning or succeed silently; our code treats origAssignee as empty → no unassign call fires in this case.        |
| 3.6 | After successful unassign, detail modal reopens                              | Assignee field shows empty. Board card loses the @assignee line.                                                                 |

## 4. Dep-type picker — new-issue modal

| #   | Scenario                                                                      | Expected                                                                                                                        |
|-----|-------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------|
| 4.1 | Open new-issue modal                                                          | Blocked by + Blocks chip-inputs each have a dep-type `<select>` below the text input, default "blocks".                          |
| 4.2 | Create a new issue with 1 blocker, default type                               | Single `bd dep add <newId> <chipId> --type blocks`. Toast: "bd-NEW created with 1 dep".                                        |
| 4.3 | Create with 3 blockers, type = parent-child                                   | Three sequential `bd dep add ... --type parent-child` calls. All chips show their type-tag pre-submit.                         |
| 4.4 | Mix: change type between adds (blocks, parent-child, blocks)                  | Each chip records its type AT add-time. Bridge calls carry the right `depType` per chip.                                        |
| 4.5 | Type picker shows all 10 types, grouped                                       | `<optgroup label="Blocking">`: blocks, parent-child, conditional-blocks, waits-for. `<optgroup label="Non-blocking">`: related, tracks, discovered-from, caused-by, validates, supersedes. |
| 4.6 | Blocker add fails (non-existent id)                                           | Issue itself was created; toast: "bd-NEW created; some deps failed: <listing>".                                                  |

## 5. Dep-type picker — detail modal add-row

| #   | Scenario                                                                       | Expected                                                                                                                          |
|-----|--------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------|
| 5.1 | Change type to "discovered-from", add a chip                                   | Chip appears in the group with the type-tag pill "discovered-from". `bd dep add` shows `--type discovered-from`.                  |
| 5.2 | Change type to "supersedes", add a chip                                        | Chip appears with type-tag "supersedes". Non-blocking type shown in the picker's "Non-blocking" optgroup.                         |
| 5.3 | Cycle dep-type (add type A, remove, re-add as type B)                          | Two separate bd calls (depRemove + depAdd). Chip rebuilds with new type.                                                          |

## 6. Per-project `--sandbox` toggle

| #   | Scenario                                                                         | Expected                                                                                                                                |
|-----|----------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------|
| 6.1 | Open `⋯` overflow menu                                                           | "Enable bd auto-push for this project" present, between the Reveal/Open-folder block and Copy-diagnostics. Unchecked by default.         |
| 6.2 | Toggle it on (first time)                                                        | Alert: "bd auto-push enabled for this project" with explanatory text. Menu item now shows ✓. Log: `auto-push ENABLED (sandbox OFF) for <root>`. |
| 6.3 | Verify subsequent bd call doesn't pass `--sandbox`                               | Next write's log line: `bd update ... → ok` with NO `--sandbox` in the argv dump. If stderr shows "dolt auto-push failed" (non-fatal), that's the expected behavior. |
| 6.4 | Toggle it back off                                                               | No alert (only the opt-in is explained). Menu item ✓ removed. Log: `auto-push disabled (sandbox ON — default)`.                         |
| 6.5 | Verify `--sandbox` is back                                                       | Next write's log line: `bd --sandbox update ... → ok`.                                                                                   |
| 6.6 | No project bound → open menu                                                     | "Enable bd auto-push…" menu item is disabled (greyed out).                                                                               |
| 6.7 | Quit NPP, relaunch, open project, check menu                                     | Toggle state persisted — ✓ still on if it was enabled last session.                                                                      |
| 6.8 | Toggle for project A, switch to project B (auto-push never enabled)              | B's menu shows unchecked. Independent per-project state — A's value didn't bleed.                                                       |
| 6.9 | Quit NPP after toggle; edit defaults: `defaults read com.notepadplusplus.app NppBeadsAutoPushProjects` | Array of project-root strings, standardized paths. Corrupted / non-string entries are silently ignored on next read.                  |
| 6.10 | Toggle on, then delete the project's `.beads/`                                  | Next bindProject: fails gracefully (JSONL fallback). Toggle setting persists; no-op on the stale entry.                                 |

## 7. Integration — Phase 3.5 with earlier phases

| #    | Scenario                                                                         | Expected                                                                                                                                 |
|------|----------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------|
| 7.1  | Live-sync poll fires mid-dep-add in detail modal                                  | Modal dep section re-renders with the new chip. Board re-renders. No duplicate chip, no error.                                           |
| 7.2  | Delete a bead → BeadsPoll detects change → _broadcastDataChanged fires             | Board card gone. Any other detail modal's dep section loses the chip on next re-render.                                                  |
| 7.3  | Switch project while a delete confirm is open                                    | Confirm dialog is modal — user must answer before project switch takes effect. No cross-project contamination.                          |
| 7.4  | Pop panel out → perform dep ops → dock back                                       | All ops work. Window key observers reinstall for the new window. Poll pauses/resumes per new window state.                              |
| 7.5  | Auto-push toggle + drag-guard + live sync all active at once                     | No deadlock, no UI corruption. Poll respects useSandbox flag from bdRunner.                                                              |

## 8. Crash / regression sentinels

| #   | Scenario                                                                          | Expected                                                                                                                           |
|-----|-----------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------|
| 8.1 | Rapid Delete → Confirm → (network/DB lag) → cancel modal close                     | Modal closes after delete completes. No crash if user did anything during the in-flight call.                                       |
| 8.2 | Open many detail modals in sequence, each with dep ops                             | No accumulation of event handlers. Memory stays bounded.                                                                            |
| 8.3 | JSONL-only backend — try every Phase 3.5 action                                   | All fail with ReadOnly. Status lines show `Install 'bd' …` or similar. No crash.                                                   |
| 8.4 | `defaults delete com.notepadplusplus.app NppBeadsAutoPushProjects` mid-session     | Next call to `_autoPushEnabledForProject:` returns NO gracefully. Menu unchecks on next open.                                       |
| 8.5 | Manually edit defaults to make NppBeadsAutoPushProjects a non-array value          | Plugin ignores the value silently. Toggle behaves as if no project is opted-in.                                                     |
| 8.6 | Bead id with special chars (leading `bd-` is standard; pathological id with `"` ) | bd rejects. Our UI doesn't corrupt; status line shows bd error.                                                                     |
