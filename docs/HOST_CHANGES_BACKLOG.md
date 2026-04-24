# Host-change backlog

Features flagged during NppBeads development that can't be implemented
plugin-side. Each requires a change in the host
(`notepad-plus-plus-macos`). All are awaiting user approval — per
standing directive, **no host changes without approval**.

Unless noted otherwise, the plugin code for each has been left at "works
as well as it can without the host change." The listed "Workaround
today" describes what users actually see right now.

---

## 1. Hover tooltip on bead-id indicator

**Surface:** Main editor (the Scintilla text area where code is edited).

**What it does:** User hovers their mouse over a bead id (e.g. `bd-a3f8`)
inside an open file → a small floating card appears inline showing that
bead's title · status · assignee. Zero-friction identification.

**Host change needed:** Forward `SCN_DWELLSTART` and `SCN_DWELLEND` to
plugins. Today they're not in the host's forward filter.
- File: `notepad-plus-plus-macos/src/NppPluginManager.mm`
- Function: `forwardScintillaNotification:`
- Roughly: add `SCN_DWELLSTART` + `SCN_DWELLEND` to the
  `if (code == SCN_CHARADDED || …)` allow-list inside `EditorView.mm`'s
  `notification:` method.
- Plugin also needs to call `SCI_SETMOUSEDWELLTIME` to opt in to dwell
  notifications (say, 400 ms).

**Plugin implementation plan (post-approval):**
1. On panel ready + per-bind, `SCI_SETMOUSEDWELLTIME` on both
   scintilla handles.
2. In `NppBeads.beNotified`, handle `SCN_DWELLSTART` → query
   `beadIdAtPosition:` on the notification's position → if hit, show
   a small NSPopover anchored at screen-position derived from
   `SCI_POINTXFROMPOSITION` / `SCI_POINTYFROMPOSITION`. Content: query
   `BdDataSource.showIssue:` and render title/status/assignee.
3. `SCN_DWELLEND` → dismiss popover.

**Workaround today:** caret + `⌘⌥⇧J` → full detail modal. Works, but is
heavier than a hover peek.

**Size:** ~2 lines of host code. ~40 lines of plugin wiring.

**Risk:** trivial. Dwell is already supported by Scintilla; the host
is just filtering it out.

---

## 2. Click-to-jump on bead-id indicator

**Surface:** Main editor.

**What it does:** User clicks a blue-painted bead id → Board detail
modal opens on that bead. Matches the visual affordance — the id is
already styled like a hyperlink.

**Host change needed:** Forward `SCN_HOTSPOTCLICK` to plugins. Same
file / function as #1.
- Single line addition to the allow-list.
- Plugin also needs the indicator configured with `SCI_INDICSETHOVERSTYLE`
  and `SCI_INDICSETHOVERFORE` to behave as a hotspot. (Or use
  `SCI_INDICSETUNDER` + the click notification arrives via position.)

**Plugin implementation plan (post-approval):**
1. In `BeadIdIndicator._installStylesIfNeeded`, set
   `SCI_INDICSETHOVERFORE` + hotspot behavior on indicator slot 25.
2. In `NppBeads.beNotified`, handle `SCN_HOTSPOTCLICK` →
   `beadIdAtPosition:` on the notification position → route through
   `showBeadDetail:`.

**Workaround today:** `⌘⌥⇧J` with caret on the id.

**Severity concern:** **this is the most impactful deferred item** —
painting ids in link-blue creates an affordance that isn't fulfilled
when clicks don't work. Users will try. Consider either landing this,
or switching the indicator to a non-link style (thin underline, muted
box) to avoid the mismatch.

**Size:** ~1 line host. ~20 lines plugin.

**Risk:** trivial.

---

## 3. Tab color-coding by bead density

**Surface:** Host tab bar (the row of file tabs above the editor).

**What it does:** Each file tab tinted by how many bead ids its buffer
contains. Heavy-reference files glow blue; empty files stay neutral.
Lets users find "the architecture doc that references half my sprint"
at a glance.

**Host change needed:** A new plugin message to set per-buffer tab
color, plus the tab bar honoring it during draw.
- New message: `NPPM_SETTABCOLOR` (wParam=bufferId, lParam=color or
  struct). Assign a free NPPMSG slot.
- File: `notepad-plus-plus-macos/src/NppTabBar.mm` — store the color
  per `_NppTabItem`, apply during paint.
- File: `NppPluginInterfaceMac.h` — declare the new message.

**Plugin implementation plan (post-approval):**
1. On NPPN_BUFFERACTIVATED, after scan completes, compute total
   matches in the full buffer (not just visible) — cap at a ceiling
   so huge files don't flood the color scale.
2. Interpolate a color from bg → accent based on density.
3. `NPPM_SETTABCOLOR` per buffer.

**Workaround today:** none. Users find files via filename / search.

**Size:** ~30 lines host. ~30 lines plugin.

**Risk:** low-medium. New plugin message is additive but touches the
tab-bar render path, which is user-visible. Requires a host dot-release.

---

## 4. Top-level "Beads" menu

**Surface:** macOS menu bar (between `Plugins` and `Window`).

**What it does:** Our three editor commands (`Jump to bead under caret`,
`Copy bead id`, `Create issue from selection`) live at the top level
instead of buried three menus deep under `Plugins → NppBeads → …`.

**Host change needed:** A plugin API to register a named top-level menu
and contribute items to it — rather than forcing every plugin command
under the shared Plugins submenu.
- Option A: new message `NPPM_REGISTERTOPLEVELMENU` taking a name and
  array of FuncItem — host inserts the menu between Plugins and Window.
- Option B: convention where a plugin whose `getName()` returns a
  specific sentinel gets promoted — less clean, but no new API.
- File: `notepad-plus-plus-macos/src/MenuBuilder.mm` + host plugin
  manager.

**Plugin implementation plan (post-approval):**
1. Call the new message in `setInfo()` with a copy of our FuncItem
   array targeting the top-level menu.
2. Likely leave Plugins → NppBeads as well for consistency with other
   plugins, or remove to avoid duplication.

**Workaround today:** commands accessible via `⌘⌥⇧J` / `⌘⌥⇧N` shortcuts
or `Plugins → NppBeads → …`. Discoverability-only cost.

**Size:** ~50 lines host. ~5 lines plugin.

**Risk:** medium. Main-menu ordering is user-visible and affects every
plugin, not just ours. Needs a design-by-precedent review (how does
Xcode / VSCode handle plugin-contributed menus?).

---

## Quick-decision summary

If you ever want to approve these piecemeal, the trade-off matrix:

| # | Surface          | Host lines | Plugin lines | User impact  | Risk   |
|---|------------------|-----------:|-------------:|--------------|--------|
| 1 | Main editor      |         ~2 |          ~40 | medium       | trivial|
| 2 | Main editor      |         ~1 |          ~20 | **high**     | trivial|
| 3 | Host tab bar     |        ~30 |          ~30 | low          | low-med|
| 4 | macOS menu bar   |        ~50 |           ~5 | low          | medium |

Recommended if you ever choose to address any: **#2 alone** is a 3-line
host diff and fixes the "blue text looks clickable but isn't"
affordance problem. Everything else is nice-to-have.
