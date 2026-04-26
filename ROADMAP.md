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

## Phase 9 — Standalone Beads.app *(~1.5–2 weeks)*

Same source tree, second CMake target. Ships a native macOS app
alongside the plugin so people who don't use Notepad++ can still use
the Rich viewer, project switcher, Board / Dashboard / Insights /
Graph / Activity, bd integration, federation, and Jira/GitHub/Linear
bridges. Single repo (`NppBeads`), two release artifacts.

### Why this is feasible at low cost

Today the plugin already separates host-coupling from
viewer/data-source code. Of 20 source files in `src/`, only
`NppBeads.mm` has heavy NPP coupling. `BeadsPanel.mm` has minor
coupling (theme detection, dock plumbing — ~30 lines).
`BeadIdIndicator` already takes its sendMessage as a function-pointer
abstraction, so it's host-agnostic. The remaining 16 files
(`BdCommandRunner`, `BdDataSource`, `JsonlDataSource`,
`BeadsDataSource`, `BeadsPoll`, `BeadsWatcher`, `BeadsProjectScanner`,
`BeadsSchemeHandler`, etc.) are pure Cocoa + bd subprocess +
WKWebView + JSONL parsing and don't know NPP exists. The Rich viewer
itself is HTML+JS in a WKWebView — the same regardless of host.

### Repo layout (single repo, dual target)

```
NppBeads/
├── src/                      shared code (16 of 20 files unchanged)
├── shell-plugin/             thin: NppBeads.mm — builds .dylib
├── shell-app/                thin: AppDelegate, MainWindowController,
│                             MenuBuilder — builds .app
├── resources/                shared (viewer/, toolbar.png, icons)
├── CMakeLists.txt            two targets, both link NppBeadsCore
└── tools/
    ├── build-plugin.sh       (existing path)
    └── build-app.sh          (new — sign + notarize + DMG the .app)
```

The 16 host-agnostic files compile into a `NppBeadsCore` static
library. Plugin shell wraps it with `setInfo` / `beNotified` /
`messageProc` exports. App shell wraps it with `NSApplicationMain` +
real Cocoa menu bar.

### Build matrix

`cmake -DNPPBEADS_BUILD_PLUGIN=ON -DNPPBEADS_BUILD_APP=ON ..` (both
default ON). `make NppBeads` builds the dylib; `make Beads`
builds the app. CI builds both, releases both as separate
artifacts on the same GitHub Release.

### Refactor work *(prerequisite, ~1–2 days)*

Pure refactor — both shells continue to work after this lands, no
behavior change.

- Introduce `BeadsHost` protocol with two methods: `isDarkMode`,
  `requestPanelDock:` (latter is a no-op in the app shell).
- `BeadsPanel` takes a `BeadsHost` instead of calling
  `_sendMessage` directly. Plugin shell implements the protocol via
  the host's NPPM_ISDARKMODEENABLED + dock requests; app shell
  implements via `NSApp.effectiveAppearance` + a no-op.
- Split CMakeLists into `core` static lib + two binary targets.

### App shell work *(~3–5 days)*

- `AppDelegate` — open last project on launch (uses existing MRU),
  save state on quit.
- `MainWindowController` — single NSWindow hosting the existing
  Rich viewer WKWebView. Title bar shows current project. Window
  position autosaved.
- Menu bar: standard macOS menus (App, File, Edit, View, Window,
  Help) plus "File → Open Project Folder…" + "File → Recent
  Projects" submenu (driven by the existing `_recordRecentProjectRoot`
  + `kBeadsRecentProjectsKey` MRU we already use).
- Settings/preferences window (NSWindowController, not WKWebView) —
  bd binary path, default arrow direction, default view mode, page
  zoom default.
- About panel with version + Beads upstream link + license.
- App icon (Beads logo + Mac platform conventions, multi-resolution).
- Optional: `NSStatusItem` menu-bar icon for "Beads is watching
  project X. ● 12 new since last visit." Click for quick peek of
  the Activity view.

### What's lost without the editor

- Bead-id highlighting in code (no editor to paint into).
- ⌘⌥⇧J jump-from-caret (no caret).
- ⌘⌥⇧N create-issue-from-selection (no selection).

These are the editor-integration killer features and they stay
exclusive to the plugin shell. The app shell users get everything
else.

### Distribution work *(~2 days)*

- Hardened-runtime entitlements for the app (`Info.plist` + entitlements
  plist). Different from plugin signing, since the app loads no
  external code.
- Code-sign with Developer ID Application + notarize + staple DMG.
- Build and ship two artifacts per GitHub Release: `NppBeads.dylib`
  (zipped, for plugin install) and `Beads.dmg` (for the app).
- README rewrite to introduce both faces: "Beads as a Notepad++
  plugin" and "Beads as a standalone Mac app." Two install paths,
  one repo.

### Branding decision *(decide before app shell starts)*

Lean toward two distinct names: `NppBeads.dylib` for the plugin,
`Beads.app` (or `Beads for macOS`) for the standalone. Same source,
same repo, same maintainer, different product brand for different
audiences. The "Npp" prefix discourages the wider audience the app
is meant to reach.

### Strategic value

Today: Beads UI for the small set of people on Notepad++ macOS.
After Phase 9: Beads UI for **anyone on macOS who uses Beads** —
Cursor / VS Code / Zed / IntelliJ / Vim / Emacs users, non-engineers
on a team (PMs, designers), agent-watchers who want a
quick-glance UI without an editor open. Upstream Beads does not
ship a native macOS viewer; this would be the first.

**Tag:** `v1.1.0` (plugin) + `Beads-v1.0.0` (app) — two tags off
the same commit, since the binaries diverge but share a tree.

---

## Remaining estimate

~10–13 working days from Phase 3 end → plugin v1.0.0 (Phases
3.5–8). Phase 5 (editor integration) is the single biggest chunk of
that and the unique value vs any other beads viewer — prioritize
accordingly.

Phase 9 adds another ~1.5–2 weeks for the standalone app, slotted
after v1.0.0 ships and the plugin proves itself in real use.
