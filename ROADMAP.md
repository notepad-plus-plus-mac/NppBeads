# NppBeads — Roadmap

Each phase ends at a tag-able state. Current: Phase 2 shipped on `main`,
Phase 1 tagged `v0.1.0`. Phase 3 starting 2026-04-23.

## Phase 1 — JSONL-backed viewer *(shipped v0.1.0)*
- `.beads/` auto-detect + JSONL parse
- Bundled dicklesworthstone viewer (Dashboard / Issues / Insights / Graph)
- `nppbeads://` custom `WKURLSchemeHandler`
- VNODE watcher with content-hash gate

## Phase 2 — Native Kanban + panel navigation *(shipped, main)*
- Toolbar: project label · view dropdown · search · theme toggle · refresh · folder · ⋯
- Native Board view (DnD between columns — optimistic only)
- Bead-detail modal in-place (click card → full detail popover)
- Rich viewer chrome stripped (header, mobile-nav, dep-graph promo)
- Graph view: layout panel removed, compact Display panel with
  Heatmap/Fire-marks/Particles toggles, Find-node isolates matches + 1-hop
- KVO on `webView.URL` syncs popup with internal viewer nav
- Dark/light theme tracks macOS; `viewDidMoveToWindow` clears ghost panel

## Phase 3 — `bd` CLI integration + editable issues *(4–5 days)*

Pivot from viewer to editor. NppBeads **writes**.

- `BdCommandRunner.{h,mm}` — NSTask wrapper for `bd` (list / show / create
  / update / close / reopen / dep add / dep remove) with `--json`,
  `--skip-hooks`, suppressed Dolt auto-push stderr noise, 750/250ms caches
- `BeadsDataSource` protocol; `JsonlDataSource` + `BdDataSource`
- Runtime `bd` detection at panel bind; read-only fallback if missing
- Board DnD persists via `bd update --status` (optimistic + rollback)
- Editable Details view (title/desc/status/priority/type/labels/assignee)
  - Markdown preview via bundled `marked.js`
  - Dependency manager: add/remove/change-type
  - "Start work" → `bd update --claim` (atomic, handles conflict)
  - "Close" → catches "blocked by open issues [...]" + Force-close retry
- "+ New issue" toolbar button with inline form
- Bridge messages: `createBead`, `updateBead`, `closeBead`, `reopenBead`,
  `depAdd`, `depRemove`

**Tag:** `v0.3.0` — first version genuinely useful daily.

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
- One-time dismissible ⚠ pill for non-fatal bd warnings (auto-push fail)
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

## Total: ~15–18 working days from Phase 2 → v1.0.0
