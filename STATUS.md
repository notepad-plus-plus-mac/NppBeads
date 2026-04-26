# NppBeads — Current Status

*Last updated: 2026-04-24 (end of Phase 6)*

## Shipped (on `main`)

| Phase | Tag       | What                                                                                          |
|-------|-----------|-----------------------------------------------------------------------------------------------|
| 1     | `v0.1.0`  | JSONL-backed viewer (bundled dicklesworthstone viewer, sql.js synthesis, file watcher)         |
| 2     | *no tag*  | Native Kanban board, toolbar, theme sync, graph polish                                         |
| 3     | *no tag*  | `bd` CLI write path: create / update / close / reopen / claim / dep add/remove                 |
| 4     | *no tag*  | Live-sync poll · project switcher dropdown · survive no-file-open · source_repo pill           |
| 3.5   | *no tag*  | Dep editor on detail modal · delete-issue · unassign · 10-type dep picker · per-project `--sandbox` toggle |
| 5     | *no tag*  | Editor integration: bead-id indicators · Jump/Copy/Create menu commands                         |
| 6     | *no tag*  | Comments thread in detail modal · Activity view · "N new" status-bar badge                     |

All phases feature-complete but **untagged** (project policy: no version
bump per user direction). Re-test locally via the matrices in
`docs/PHASE{3,3_5,4,5,6}_TEST_MATRIX.md`.

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
    ├── NppBeads.mm              # plugin entry + menu registration + editor hooks
    ├── BeadsPanel.{h,mm}        # panel view, WKWebView host, bridge handlers, switcher
    ├── BeadsDataSource.h        # protocol (read/write operations)
    ├── JsonlDataSource.{h,mm}   # read-only fallback (no `bd` needed)
    ├── BdDataSource.{h,mm}      # writable, wraps BdCommandRunner
    ├── BdCommandRunner.{h,mm}   # NSTask wrapper (prepends --sandbox conditionally)
    ├── BeadsProjectScanner.mm   # walks up from file, scans recents for switcher
    ├── BeadsWatcher.mm          # dispatch_source VNODE watcher
    ├── BeadsPoll.{h,mm}         # 2s bd list poll w/ hash-diff + focus pause
    ├── BeadIdIndicator.{h,mm}   # Phase 5: scans editor, paints indicator, caches
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

**Phase 3.5 editing extras**
- Dep editor in detail modal: existing deps shown as removable chips
  with type-tag, add-row with full 10-type picker (blocks / parent-child
  / conditional-blocks / waits-for / related / tracks / discovered-from
  / caused-by / validates / supersedes). Re-renders after every op.
- New-issue modal's Blocked-by and Blocks chip-inputs each carry their
  own type picker; each chip records its type at add-time.
- Delete-issue button (detail modal, red, between Claim and Cancel).
  Confirm lists up to 8 dependents so the user knows what edges will
  drop. bd cleans up dangling dep rows server-side.
- Unassign — clearing a previously-set assignee in the Save form routes
  through `unassignBead` (bd's `--unassign`) before the regular update.
  Fixes the silent no-op where `--assignee ""` was ignored.
- Per-project `--sandbox` toggle (⋯ menu → "Enable bd auto-push for
  this project"). Default is sandbox ON (auto-push disabled, 100×
  faster). Opt-in is persisted in `NppBeadsAutoPushProjects` defaults;
  BdCommandRunner.useSandbox applied at bind time.

**Phase 5 editor integration**
- `BeadIdIndicator` scans the active editor's visible range for
  `\b<prefix>-[a-z0-9]+(\.\d+)*\b` (Scintilla C++11 regex via
  SCFIND_CXX11REGEX) and paints indicator slot 25 as INDIC_TEXTFORE
  blue. Debounced at 150 ms via SCN_MODIFIED / SCN_UPDATEUI / SCN_PAINTED.
- `Plugins → NppBeads → Jump to bead under caret` (⌘⌥⇧J) — opens the
  panel + Board + detail modal on whatever bead id the caret is on.
  Fallback ±64-byte scan for cases where the cache is stale.
- `Plugins → NppBeads → Copy bead id under caret` — writes to pasteboard.
- `Plugins → NppBeads → Create issue from selection` (⌘⌥⇧N) — prefills
  the Board's new-issue title with the editor selection (capped 4 KB,
  whitespace collapsed).
- `_pendingPostLoadJS` queue survives the dashboard-load → board-load
  transition on first panel-show.

**Phase 6 comments + activity**
- Comments thread in the detail modal, under the dep editor. Markdown
  rendered via marked.min.js + DOMPurify sanitization. ⌘↵ submits.
- `fetchBead` bridge pulls the full `bd show --json` record
  (JSONL export omits comments).
- `addCommentToIssue` pipes body via stdin so multi-line markdown,
  quotes, `$`, backticks all survive.
- Activity view mode (`app/activity.html`): reverse-chron flat list of
  issues by updated_at. Clicks route to Board detail modal via
  `openBeadModal` bridge.
- "N new" status-bar badge: per-project last-Activity-visit timestamp
  in `NppBeadsLastActivityVisit` defaults; count of issues with
  `updated_at` > lastVisit. Acknowledged when user visits Activity.
  Refreshes on window-key-became so the badge updates on refocus.

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

## Phase 3.5 — shipped

All five deferred items landed:
- ✅ Dep add/remove on the existing-issue detail modal
- ✅ Delete-issue action with confirm + dep-sweep warning
- ✅ `--unassign` wiring on the detail-modal Save path
- ✅ Full 10-type dep picker (both new-issue and detail modal)
- ✅ Per-project sandbox opt-out (overflow-menu toggle)

## Next major phases

See `ROADMAP.md` for full detail.

- **Phase 7** — Polish (saved filters, keyboard shortcuts, status-bar chip)
- **Phase 8** — Notarization + distribution (target: plugin `v1.0.0`)
- **Phase 9** — Standalone `Beads.app` built from the same source tree;
  same repo, dual CMake target, separate signed/notarized DMG. Target:
  app `v1.0.0` (~1.5–2 weeks after plugin v1.0.0).

Estimated ~4 working days remaining to plugin `v1.0.0` assuming no scope
creep. App ships ~1.5–2 weeks after that.

## Flagged for host-change approval (Phase 5 polish)

Plugin-side can't implement these without a host surface change:

- **Hover tooltip on bead-id indicator** — needs `SCN_DWELLSTART` in
  the host's forward filter (currently not forwarded).
- **Click-to-jump on indicator** — needs `SCN_HOTSPOTCLICK` forwarded.
  Today users place caret on the id and hit ⌘⌥⇧J.
- **Tab color-coding by bead density** — needs a host plugin API for
  per-buffer tab tinting.
- **Top-level "Beads" menu** — plugin menus currently live under
  "Plugins". Our three editor commands sit at `Plugins → NppBeads →`.

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
- Phase 4 commits on main (no tag): `ee5931c` (BeadsPoll) · `4f30c9f` (switcher + survive no-file-open) · `2335eb0` (source_repo pill) · `ae419ef` (probe-race fix + docs) · `2dfab91` (chevron fix)
- Phase 3.5 commits on main (no tag): `e04536e` (native delete + unassign + sandbox toggle) · `bcb382d` (JS dep manager + delete + unassign + type picker)
- Phase 5 commit on main (no tag): `70ba3f9` (indicator + menu commands)
- Phase 6 commit on main (no tag): `197d14e` (comments + activity + badge)
- `main` is pushed and current
