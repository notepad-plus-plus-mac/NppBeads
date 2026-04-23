# NppBeads — Current Status

*Last updated: 2026-04-23 (end of Phase 4)*

## Shipped (on `main`)

| Phase | Tag       | What                                                                                          |
|-------|-----------|-----------------------------------------------------------------------------------------------|
| 1     | `v0.1.0`  | JSONL-backed viewer (bundled dicklesworthstone viewer, sql.js synthesis, file watcher)         |
| 2     | *no tag*  | Native Kanban board, toolbar, theme sync, graph polish                                         |
| 3     | *no tag*  | `bd` CLI write path: create / update / close / reopen / claim / dep add/remove                 |
| 4     | *no tag*  | Live-sync poll · project switcher dropdown · survive no-file-open · source_repo pill           |

Phases 3 and 4 are feature-complete but **untagged** (project policy: no
version bump per user direction). Re-test locally via the matrices in
`docs/PHASE3_TEST_MATRIX.md` + `docs/PHASE4_TEST_MATRIX.md`.

## Working project tree

```
/Users/leto/development/npp/nppPluginsMacOS/NppBeads/
├── CMakeLists.txt
├── README.md                    # User-facing intro (Phase 1 era; needs refresh)
├── ROADMAP.md                   # All 8 phases
├── STATUS.md                    # This file
├── ARCHITECTURE.md              # Code + bridge protocol reference
├── docs/
│   └── PHASE3_TEST_MATRIX.md    # 40-row manual regression checklist
├── resources/
│   └── viewer/                  # bundled web viewer (dicklesworthstone + app/*)
│       ├── bridge.js            # JS → native bridge (createBead/updateBead/…)
│       ├── app/                 # native board / issue / detail pages
│       │   ├── board.html       # Kanban view
│       │   ├── board.js         # DnD, create modal, edit modal
│       │   ├── app.css
│       │   └── app.js           # shared helpers
│       └── vendor/              # sql-wasm, alpine, d3, …
└── src/
    ├── NppBeads.mm              # plugin entry + menu registration
    ├── BeadsPanel.{h,mm}        # panel view, WKWebView host, bridge handlers, switcher
    ├── BeadsDataSource.h        # protocol (read/write operations)
    ├── JsonlDataSource.{h,mm}   # read-only fallback (no `bd` needed)
    ├── BdDataSource.{h,mm}      # writable, wraps BdCommandRunner
    ├── BdCommandRunner.{h,mm}   # NSTask wrapper (prepends --sandbox)
    ├── BeadsProjectScanner.mm   # walks up from file, scans recents for switcher
    ├── BeadsWatcher.mm          # dispatch_source VNODE watcher
    ├── BeadsPoll.{h,mm}         # 2s bd list poll w/ hash-diff + focus pause
    └── BeadsSchemeHandler.mm    # nppbeads:// URL scheme → same-origin
```

## What you can do right now in the UI

**Board view**
- Drag-and-drop between columns → `bd update --status` persists
- Raw / Effective mode toggle (top-left)
- "+ New issue" modal (top-right) with:
  - title / type / priority / labels / description
  - Blocked-by chip-input (autocomplete from current beads)
  - Blocks chip-input (downstream deps)
- Click card → editable detail modal:
  - Save (diffs vs original; sends only changed fields)
  - Close (offers force-on-blocked confirm)
  - Reopen (on closed issues)
  - Claim
- `source_repo` chip on cross-repo cards (hidden when `.` or absent)

**Status bar**
- `<project> · N issues (o/b/c) · <backend>` where backend = `bd vX.Y.Z` or `read-only (JSONL)`

**Project switcher (Phase 4)**
- Click the project name (top-left chip with ▾) → dropdown
- Menu offers: current · recent projects (cross-session MRU + session-seen paths + NSDocumentController recents) · **Open .beads folder…** · **Unbind current project**
- Recents filtered on read — stale entries (deleted .beads/) get auto-pruned
- Also available from `⋯` → "Switch project…"

**Project detection (Phase 4 semantics)**
- Walks up from the active file looking for `.beads/` — but the auto-detect
  can only SWITCH to a matching project, never clear one. Scratch-file
  edits and closing the last file do **not** wipe the panel. Explicit
  unbind is the switcher's "Unbind current project" entry.

**Live sync (Phase 4)**
- 2 s bd list poll with hash-diff, pauses when the host window isn't key
- On detected change → in-place re-broadcast (no page reload)
- Drag-in-progress guard: poll- or watcher-triggered renders during a
  card drag defer until dragend, preventing the dragged node from being
  yanked

## Key performance/UX decisions

- **`--sandbox` on every bd call.** Disables dolt auto-push. Cuts bd
  write latency from ~23 s to ~0.2 s on projects without non-interactive
  git auth (the common case). Users who want replication run `bd sync`
  from a terminal.
- **Optimistic UI everywhere.** DnD, create, edit all move the UI before
  bd answers; the `_broadcastDataChanged` refresh is the reconcile step.
- **Serial dep writes.** bd's embedded Dolt backend deadlocks on
  concurrent writes within one project — `depAdd` calls are awaited in
  a loop, not `Promise.all`.
- **Bridge type/issueType split.** The bridge envelope's `type` field
  is the message name (`updateBead`, etc.). Bead-issue-type lives under
  `issueType` and dep kind under `depType`. Reading the envelope's
  `type` as the bd `--type` flag was a real bug we fixed (see commit
  `7524427` predecessor).

## Deferred to Phase 3.5

- Dep add/remove on the **existing-issue** detail modal (creation-only today)
- Delete-issue action with confirm (use `bd delete <id>` in CLI)
- Clear-assignee wiring (needs `bd update --unassign`; today empty field is ignored)
- Non-`blocks` dep types in the UI (`tracks`, `related`, `parent-child`, `discovered-from`, `until`, `caused-by`, `validates`, `relates-to`, `supersedes`)
- A toggle to disable `--sandbox` per-project for users who actually want auto-push

## Next major phases

See `ROADMAP.md` for full detail.

- **Phase 5** — Editor integration (bead-id scanner + Scintilla indicators + hover tooltips) — the real differentiator vs a standalone viewer
- **Phase 6** — Comments + activity feed
- **Phase 7** — Polish (saved filters, keyboard shortcuts, status-bar chip)
- **Phase 8** — Notarization + distribution (target: `v1.0.0`)

Estimated ~7–10 working days remaining to `v1.0.0` assuming no scope creep.

## Build + install one-liner

```bash
cd /Users/leto/development/npp/nppPluginsMacOS/NppBeads/build && \
  cmake --build . --target install
```

Output: `~/.notepad++/plugins/NppBeads/NppBeads.dylib` + resources/.
The **host app must be quit** before rebuilding — the dylib is locked
while Notepad++ is running.

## Git

- Repo: `github.com:notepad-plus-plus-mac/NppBeads.git`
- Phase 3 final commit: `7ec1480` (Phase 3 closeout)
- Phase 4 commits on main (no tag): `ee5931c` (BeadsPoll) · `4f30c9f` (switcher + survive no-file-open) · `2335eb0` (source_repo pill)
- `main` is pushed and current
