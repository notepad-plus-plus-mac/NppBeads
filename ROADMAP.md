# NppBeads — Roadmap

Each phase ends at a tag-able state.
**Current:** Phase 3 shipped on `main` (untagged), heading into Phase 3.5 / Phase 4.

## Phase 1 — JSONL-backed viewer *(shipped v0.1.0)*
- `.beads/` auto-detect + JSONL parse
- Bundled dicklesworthstone viewer (Dashboard / Issues / Insights / Graph)
- `nppbeads://` custom `WKURLSchemeHandler`
- VNODE watcher with content-hash gate

## Phase 2 — Native Kanban + panel navigation *(shipped, main)*
- Toolbar: project label · view dropdown · search · theme toggle · refresh · folder · ⋯
- Native Board view (DnD between columns — optimistic only at the time)
- Bead-detail modal in-place (click card → full detail popover)
- Rich viewer chrome stripped (header, mobile-nav, dep-graph promo)
- Graph view: layout panel removed, compact Display panel with
  Heatmap/Fire-marks/Particles toggles, Find-node isolates matches + 1-hop
- KVO on `webView.URL` syncs popup with internal viewer nav
- Dark/light theme tracks macOS; `viewDidMoveToWindow` clears ghost panel

## Phase 3 — `bd` CLI integration + editable issues *(shipped 2026-04-23, `main`)*

Pivot from viewer to editor — NppBeads **writes**.

Shipped across 7 commits (`4007622` → `7ec1480`):

- **`BdCommandRunner.{h,mm}`** — NSTask wrapper for `bd` (list / show /
  create / update / close / reopen / claim / dep add / dep remove) with
  `--json`, `--sandbox` always-on (100× write-speedup by skipping bd's
  failing auto-push), 750/250 ms read caches, structured error
  classification, multi-line warning-block-aware stderr scrape
- **`BeadsDataSource`** protocol; `JsonlDataSource` (read-only) +
  `BdDataSource` (writable)
- Runtime `bd` detection at panel bind; backend label in status bar
- Board DnD persists via `bd update --status` (optimistic + rollback)
- Editable detail modal (title / desc / status / priority / type /
  labels / assignee / description with markdown textarea)
  - Save button diffs vs original; sends only changed fields
  - `Close` catches "blocked by open issues [...]" → `confirm()` shows
    blockers → retries with `--force`
  - `Reopen` shown instead of Close when status = closed
  - `Claim` → `bd update --claim` (atomic)
- **"+ New issue"** modal with:
  - title / type / priority / labels / description
  - **Blocked-by** chip-input (upstream deps)
  - **Blocks** chip-input (downstream deps)
  - Single shared `<datalist>` for autocomplete over current beads
  - Sequential `depAdd` calls after create — bd deadlocks on concurrent
    writes in the same project
- **Raw / Effective status toggle** on the Board (top-left)
  - Raw: groups by the stored `status` field
  - Effective: promotes open/in-progress issues with at least one
    non-closed `blocks` dep into the Blocked column (matches `bd ready`
    / `bd status` semantics)
- Bridge messages: `createBead`, `updateBead`, `closeBead`, `reopenBead`,
  `claimBead`, `depAdd`, `depRemove`, all via
  `window.__nppBridge.call()` returning Promises
- `docs/PHASE3_TEST_MATRIX.md` — 40-row manual regression checklist

**Scope deferred to Phase 3.5:**
- Dep add/remove on existing-issue detail modal
- Delete-issue action (`bd delete <id>`)
- Clear-assignee (`bd update --unassign`)
- Non-`blocks` dep types in the UI (`tracks`, `related`, `parent-child`,
  `discovered-from`, `until`, `caused-by`, `validates`, `relates-to`,
  `supersedes`)
- Setting to disable `--sandbox` for users with working non-interactive
  git auth who want auto-push

**Tag:** `v0.3.0` — first version genuinely useful daily (pending
local re-test after `--sandbox` behavior change).

## Phase 3.5 — Dep editor + polish *(1–2 days, optional)*
- Dep manager inline in the existing-issue detail modal (add + remove
  + change-type, reusing the chip-input component)
- Delete-issue button with `confirm()` and dep-sweep warning
- `--unassign` wiring for clear-assignee
- Dep-type picker (dropdown next to each chip) exposing all 10 bd
  dep types; default stays `blocks`
- Per-project `--sandbox` toggle in panel settings

## Phase 4 — Live sync + project switcher *(2–3 days)*
- 2s poll of `bd list --json`, hash diff → `data-changed` signal; all
  views subscribe with partial render
- Project switcher dropdown (workspace scan + recent projects in
  NSUserDefaults); survives closing all files
- `source_repo` pill on cards for multi-repo awareness
- Poll pauses when panel loses focus

**Tag:** `v0.4.0`.

## Phase 5 — Editor integration (NppBeads differentiator) *(3–4 days)*
- `BeadIdScanner.{h,mm}` — regex `\b<prefix>-[a-z0-9]+(\.\d+)*\b` over
  visible range; re-scan on `SCN_MODIFIED` + `NPPN_BUFFERACTIVATED`
- `BeadIdIndicator.{h,mm}` — Scintilla indicator + hotspot → panel opens
  Details view on clicked bead
- Hover tooltip: title · status · assignee via `SCI_POINTXFROMPOSITION`
- Menu: `Beads ▸ Jump to bead under caret` (⌘⇧G), `Copy bead id`,
  `Create issue from selection`
- Tab color-coding by referenced-bead density

**Tag:** `v0.5.0`.

## Phase 6 — Comments + activity feed *(2 days)*
- Comments thread in Details view (`bd show --json .comments[]`;
  `bd comment add <id>`)
- Markdown render on same path as description
- Activity feed view mode — reverse-chron across open issues
- Status-bar "N new comments" badge when panel regains focus

**Tag:** `v0.6.0`.

## Phase 7 — Polish *(2 days)*
- Saved filter presets on Board / Issues
- Keyboard shortcuts: N/E/C/G/`/` for new/edit/close/graph/search
- Light-mode theme pass on Rich viewer
- `bd dolt status` chip in status bar (30s poll)
- One-time dismissible ⚠ pill for non-fatal bd warnings (auto-push fail,
  permissions Warning)
- "Copy diagnostics" bundle action

**Tag:** `v0.9.0-rc1`.

## Phase 8 — Distribution *(2 days)*
- Notarization pipeline (Developer ID Application, stapled DMG)
- README with screenshots + 30s video GIF
- Submit to `nppPluginList/pl.macos-arm64.json` (host change — needs
  approval)
- PR to `gastownhall/beads/docs/COMMUNITY_TOOLS.md` for listing
- GitHub Release v1.0.0

**Tag:** `v1.0.0` — shipped publicly.

---

## Remaining estimate

~10–13 working days from Phase 3 end → v1.0.0, assuming no scope creep.
Phase 5 (editor integration) is the single biggest chunk and the unique
value vs any other beads viewer — prioritize accordingly.
