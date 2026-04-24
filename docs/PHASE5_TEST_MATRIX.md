# Phase 5 End-to-End Test Matrix

Manual regression for the Phase 5 editor-integration features:
`BeadIdIndicator` (paint + cache), SCN notification wiring, and the
three plugin commands (Jump / Copy / Create). Runs inside Notepad++
with a sample file that contains a handful of bead ids in comments or
prose.

Each check is **pass** only if observed behavior matches "Expected"
AND (where relevant) the Console.app log line agrees (filter: `NppBeads`).

## 0. Setup

Open any text buffer and paste this into it:

```
TODO: fix bd-a3f8 before ship; bd-deadbeef supersedes bd-b1.
Nested: bd-a3f8.1.2 is a child of bd-a3f8.
Not a bead: bd- (no tail), dash-case-word, en-us.
```

Row `0.0`: The five tokens `bd-a3f8`, `bd-deadbeef`, `bd-b1`,
`bd-a3f8.1.2`, `bd-a3f8` (repeat) render in blue (link-style color).
Negatives (`bd-`, `dash-case-word`, `en-us`) stay in the normal
text color.

## 1. Painting

| #   | Scenario                                                             | Expected                                                                                                           |
|-----|----------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------|
| 1.1 | Scroll down past visible range then back up                          | Indicators still visible where they were. No flicker on scroll-back.                                               |
| 1.2 | Scroll to a new region that has bead ids                             | New ids appear blue within ~150 ms of SCN_PAINTED (debounced rescan).                                              |
| 1.3 | Edit an existing bead id inline (insert char in middle)              | Indicator range expands with the edit (Scintilla behavior). After 150 ms the rescan re-colors the new span.        |
| 1.4 | Delete a bead id entirely                                            | Indicator vanishes after rescan. No ghost color on whitespace.                                                     |
| 1.5 | Switch tabs to a buffer with no bead ids                             | Previous buffer's indicators stay in that buffer (doc-scoped). New buffer has no coloring.                        |
| 1.6 | Switch back to the buffer with ids                                   | Indicators still there (Scintilla indicators persist in the doc state).                                            |
| 1.7 | Split view (File → Move to Other View) showing same buffer           | Both views show the same indicators (shared document).                                                             |
| 1.8 | Huge file (~10 MB, ~100k lines) with ids scattered                   | Scan cost stays sub-100 ms per rescan (visible range only). No editor lag.                                         |
| 1.9 | Paste a block with 50 bead ids                                       | All colored within one debounce interval. No hang.                                                                 |

## 2. Jump to bead under caret (⌘⌥⇧J)

| #   | Scenario                                                             | Expected                                                                                                          |
|-----|----------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------|
| 2.1 | Caret in the middle of `bd-a3f8`                                     | Panel shows → switches to Board → detail modal opens on bd-a3f8.                                                  |
| 2.2 | Caret at the first char of `bd-a3f8`                                 | Same as above (inclusive bounds).                                                                                 |
| 2.3 | Caret just after the last char of `bd-a3f8`                          | Same as above (inclusive bounds).                                                                                 |
| 2.4 | Caret on plain text (no bead id nearby)                              | NSBeep. No panel action. No Console error.                                                                        |
| 2.5 | Bead id exists but isn't in this project's issue list                | Panel switches to Board → modal opens → modal shows "Issue not found in current project data."                    |
| 2.6 | Fire before any buffer has been active                               | NSBeep. No crash.                                                                                                 |
| 2.7 | Panel hidden when shortcut fires                                     | Panel auto-shows, then opens modal (via ensurePanel + cmdTogglePanel + showBeadDetail chain).                     |
| 2.8 | Panel on Dashboard view when shortcut fires                          | View switches to Board (_pendingPostLoadJS fires in didFinishNavigation). Modal opens.                            |
| 2.9 | Caret just BEFORE the cache was built (fresh buffer)                 | Fallback ±64-byte window scan catches it. No NSBeep on valid ids.                                                 |

## 3. Copy bead id

| #   | Scenario                                                             | Expected                                                                                                 |
|-----|----------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------|
| 3.1 | Caret on `bd-a3f8`, invoke command                                   | NSPasteboard contains `bd-a3f8`. No Console error.                                                       |
| 3.2 | Caret on plain text                                                  | NSBeep. Pasteboard unchanged.                                                                            |
| 3.3 | Caret on nested id `bd-a3f8.1.2`                                     | Pasteboard contains the full nested id including dotted suffix.                                         |

## 4. Create issue from selection (⌘⌥⇧N)

| #   | Scenario                                                                    | Expected                                                                                                       |
|-----|-----------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------|
| 4.1 | Select a short phrase "Add dark mode"                                       | Panel → Board → new-issue modal opens with title field = "Add dark mode". Focus lands on title.                |
| 4.2 | No selection (caret only)                                                   | Panel → Board → new-issue modal opens with empty title.                                                        |
| 4.3 | Multi-line selection                                                        | Newlines collapsed to single spaces, internal whitespace normalized.                                            |
| 4.4 | Huge selection (> 4 KB)                                                     | Capped at 4096 bytes. Title may be truncated mid-word; acceptable.                                              |
| 4.5 | Selection with quotes / `$` / backticks                                     | Title prefilled verbatim. No broken JS, no shell-expansion issues (we pass the string via eval with escaping). |
| 4.6 | Panel not yet ever shown                                                    | Panel auto-shows, opens Board, opens new-issue modal with prefill. No race.                                     |

## 5. Two-view behavior

| #   | Scenario                                                            | Expected                                                                                                       |
|-----|---------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------|
| 5.1 | View → Move Current Tab to Other View                               | NPPN_BUFFERACTIVATED fires → indicator handle switches → rescan against the new focused Scintilla instance.   |
| 5.2 | Jump-to-bead while focus is in the secondary view                   | Reads caret from the secondary view (currentScintillaHandle resolves via NPPM_GETCURRENTSCINTILLA).           |

## 6. Diagnostics / crash sentinels

| #   | Scenario                                                                   | Expected                                                                                                    |
|-----|----------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------|
| 6.1 | Trigger shortcut before setInfo finished (extremely early)                 | NSBeep or silent no-op. No segfault.                                                                        |
| 6.2 | Macro record / playback while indicators are active                        | Plugin notification forwarding is suppressed during macro playback (host behavior) — no double-paint loops. |
| 6.3 | NPP quit while rescan is pending (150 ms window)                           | Clean shutdown. sIndicator.clearAll is called on NPPN_SHUTDOWN before teardown.                             |
| 6.4 | Rapid editing storms (100 keystrokes/s)                                    | Only one rescan fires per debounce interval. Editor stays responsive.                                       |

## 7. Known deferred (need host changes — not this phase)

- **Hover tooltip on indicator** — requires SCN_DWELLSTART forwarding.
- **Click-to-jump on indicator** — requires SCN_HOTSPOTCLICK forwarding.
  Current UX: user places caret on the id and hits ⌘⌥⇧J.
- **Tab color-coding by bead density** — requires a host-side tab-color
  plugin API.
- **Top-level "Beads" menu** — plugin menus live under "Plugins".
  Our three commands are at `Plugins → NppBeads → …`.
