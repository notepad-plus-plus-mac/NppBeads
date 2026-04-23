# Phase 4 End-to-End Test Matrix

Manual regression suite for live sync, project switcher, survive-no-file,
and the source_repo pill. Run through before pushing any NppBeads build
that touches these surfaces.

Each check is **pass** only if the observed state matches "Expected"
**and** (where relevant) the Console.app log line agrees (filter:
`NppBeads`).

## 1. Live sync (BeadsPoll)

| # | Scenario                                                           | Expected                                                                                                                               |
|---|--------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------|
| 1.1 | Panel focused; terminal `bd update <id> --status in_progress`    | Log: `poll detected change (#N) — rebroadcasting` within 2 s. Card moves without a page reload. Status-bar counts update.           |
| 1.2 | Panel blurred (focus Finder); same terminal write                | No `poll detected change` log while blurred. On refocus: log `poll tick N: …` resumes and any accumulated change is picked up.       |
| 1.3 | Terminal writes 3 times in rapid succession (same second)        | Only one broadcast per poll interval — hash-diff swallows duplicate states once settled.                                              |
| 1.4 | Very large project (500+ beads)                                    | Poll tick cost remains < 300 ms on a warm Dolt. Diagnostics dump `poll: ticks=N changes=M`.                                           |
| 1.5 | `bd` binary removed mid-session (`sudo mv /opt/homebrew/bin/bd …`) | Next tick logs `poll tick N: bd list failed (…)`. No crash. No UI change until restored.                                               |
| 1.6 | Project has no `.beads/` (JSONL-fallback backend)                  | Diagnostics dump says `poll: (not active — JSONL backend)`. No timer overhead.                                                         |
| 1.7 | Alt-tab away + back rapidly (10× within 5 s)                       | Pause/resume count ticks up, but no extra bd processes spawn (verify via `ps`). Timer is not torn down per toggle.                     |
| 1.8 | Switch projects while poll is mid-tick (in-flight bd call)         | Log: `probe completion ignored — superseded by later bindProject` OR the new project's bd call replaces cleanly. No crash.             |
| 1.9 | Click Refresh button                                               | Log: `reloadData` runs **and** poll's `lastPayload` is re-baselined (next tick doesn't fire a ghost `poll detected change`).           |
| 1.10 | Dock → Float → Dock panel (pop-out / dock-back)                    | Poll continues across transitions. Window-key observers re-bind each time (log via viewDidMoveToWindow). No leak, no double-fire.      |

## 2. Drag-guard

| # | Scenario                                                                        | Expected                                                                                                              |
|---|---------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------|
| 2.1 | Start dragging a card; terminal writes mid-drag (any bd update)                | No visual yank during the drag. On dragend, the deferred render runs once. Final state is correct.                     |
| 2.2 | Drag a card and drop OUTSIDE any column / outside the panel                    | dragend still fires. Guard clears. No stuck state.                                                                     |
| 2.3 | Drag a card and let it hang 10 s without dropping (watchdog)                   | After 8 s, guard auto-releases. Deferred render (if any) runs. Guard won't deadlock UI indefinitely.                   |
| 2.4 | Cancel drag with ESC mid-drag                                                   | dragend fires. Guard clears. No pending lockout.                                                                       |
| 2.5 | Drag + drop producing a status change; poll tick fires immediately after drop   | One render (not two). Optimistic move is reconciled against bd-confirmed result. No flicker.                            |

## 3. Project switcher — dropdown mechanics

| #  | Scenario                                                                   | Expected                                                                                                                       |
|----|----------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------|
| 3.1 | Click project chip with a project bound                                   | Menu opens under the chip. First row is the project name with ✓ (disabled). Tooltip shows full path.                          |
| 3.2 | Click project chip with no project bound                                   | Menu opens. No ✓ header row. Just "Open .beads folder…" (no Unbind item).                                                     |
| 3.3 | Recent projects listed (after you've bound A, B, C)                        | B and C shown as menu items, leaf names, tooltip = full path. Current (A) appears only as the ✓ header, not duplicated below.  |
| 3.4 | Two projects with identical leaf names (e.g. two `/*/notes/` repos)         | Both appear in the list. Tooltips disambiguate on hover.                                                                       |
| 3.5 | Session seen-paths discovery (touched files in project D without binding)  | D appears in the menu's recents once its `.beads/` is reached by walk-up (after activating a file inside it).                   |
| 3.6 | `⋯` overflow menu → "Switch project…"                                       | Opens the same switcher menu as the chip.                                                                                     |

## 4. Project switcher — actions

| #  | Scenario                                                              | Expected                                                                                                                      |
|----|-----------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------|
| 4.1 | Pick a recent project from dropdown                                   | Panel rebinds. Project chip title updates. Status bar reflects new project's counts. Poll restarts for the new project.         |
| 4.2 | "Open .beads folder…" → pick a valid `.beads/` directory              | Panel binds to that project. Entry is prepended to recents (next click shows it at top).                                        |
| 4.3 | "Open .beads folder…" → pick a project ROOT (not `.beads/`)           | Auto-canonicalizes to `<root>/.beads`, validates, binds if usable.                                                              |
| 4.4 | "Open .beads folder…" → pick a non-beads directory                    | Alert: "Not a beads project". No side effects.                                                                                  |
| 4.5 | "Open .beads folder…" → Cancel                                        | No-op. No console error.                                                                                                        |
| 4.6 | "Unbind current project"                                              | Project chip reverts to "(no project) ▾". Status bar: "no project · click the project name ▾ to pick one". Poll stops.           |
| 4.7 | Pick a recent whose `.beads/` has since been deleted                  | Alert: "Project not found". Entry auto-pruned from defaults. Next menu open no longer shows it.                                 |
| 4.8 | Corrupt `NppBeadsRecentProjectRoots` in defaults (non-string / relative paths) | Invalid entries silently skipped. Good entries still usable.                                                             |
| 4.9 | First launch (no recents)                                              | Menu shows only "Open .beads folder…" (no recent section, no separator).                                                        |

## 5. Survive no-file-open

| #  | Scenario                                                                   | Expected                                                                                                                      |
|----|----------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------|
| 5.1 | Panel bound to project A; close all files                                  | Panel keeps showing A. No "(no project)".                                                                                     |
| 5.2 | Panel bound to A; open a scratch file in `/tmp/`                           | Panel keeps showing A. No flip to "(no project)".                                                                             |
| 5.3 | Panel bound to A; open a file inside project B                             | Panel auto-switches to B. (Last-touch-wins — Model B.)                                                                        |
| 5.4 | User picks B via switcher; activates a file in A                           | Panel auto-switches to A. (Still Model B — manual picks don't override subsequent auto-detect hits.)                           |
| 5.5 | No files open, no prior binding (fresh launch)                             | Project chip "(no project) ▾". Status bar hint. Switcher still openable.                                                       |
| 5.6 | Toggle panel off → on with no files open                                   | Panel shows last-bound project on re-open. prepareForShow does NOT clear it.                                                  |

## 6. Persistence

| #  | Scenario                                                                   | Expected                                                                                                                      |
|----|----------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------|
| 6.1 | Bind project A via switcher; quit + relaunch NPP                           | A appears in the switcher's recents on next launch. Panel auto-binds via active file OR user clicks A from switcher.           |
| 6.2 | Bind 15 different projects in one session                                  | Recents list capped at 10 most-recent. Oldest 5 evicted.                                                                       |
| 6.3 | Re-bind A after B, C, D                                                    | A moves to top of recents (dedup-then-prepend). No duplicate entries.                                                          |
| 6.4 | Verify defaults key name                                                   | `defaults read com.notepadplusplus.app NppBeadsRecentProjectRoots` prints an array of absolute paths, MRU-ordered.             |

## 7. source_repo pill (Board only)

| #  | Scenario                                                               | Expected                                                                                                                |
|----|------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------|
| 7.1 | Bead with `source_repo: "."`                                           | No chip.                                                                                                                 |
| 7.2 | Bead with `source_repo: ""` or field absent                             | No chip.                                                                                                                 |
| 7.3 | Bead with `source_repo: "other-repo"`                                    | Chip renders reading "other-repo", muted style. Hover tooltip: `source: other-repo`.                                    |
| 7.4 | Bead with path-like `source_repo: "github.com/foo/bar"`                  | Chip reads "bar". Hover tooltip: `source: github.com/foo/bar`.                                                           |
| 7.5 | Long `source_repo` value (> 120px rendered)                              | Chip truncates with ellipsis. Tooltip shows full value.                                                                  |

## 8. Crash / regression sentinels

| #  | Scenario                                                                   | Expected                                                                                                                      |
|----|----------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------|
| 8.1 | Quit NPP while poll is mid-tick                                            | Clean shutdown. Generation counter gates the in-flight completion. No segfault, no zombie bd process.                     |
| 8.2 | Rebind rapidly across 5 projects in < 2 s                                   | One final poll attached to the last-bound project. Probe completions for superseded binds log "ignored" and bail.           |
| 8.3 | Pop panel out to floating window while poll is active                       | Poll continues. `viewDidMoveToWindow` re-installs window-key observers against the NSPanel. Pause works on the new window. |
| 8.4 | Diagnostics dump (right-click → "Copy diagnostics")                         | Includes `poll: ticks=N changes=M skips(inflight)=K paused=YES|NO` OR `poll: (not active — JSONL backend)`.                 |
