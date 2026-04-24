# Phase 6 End-to-End Test Matrix

Manual regression for the Phase 6 deliverables: comments thread in the
detail modal, `bd comment add` wiring, Activity view mode, and the
"N new" status-bar badge.

Each check is **pass** only if observed behavior matches "Expected" AND
(where relevant) the Console.app log line agrees (filter: `NppBeads`).

Pre-req for writes: a project with the `bd` backend (status bar shows
`bd vX.Y.Z`). Comments are writes, so JSONL-only projects are
read-only for this matrix.

## 1. Comments thread — rendering

| #    | Scenario                                                              | Expected                                                                                                           |
|------|-----------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------|
| 1.1  | Open a bead with no comments                                           | "Comments" section under dep editor. Shows "No comments yet." while `fetchBead` runs; after fetch: same.          |
| 1.2  | Open a bead with comments                                              | Each comment renders as a row with `@author` + timestamp + markdown body.                                          |
| 1.3  | Markdown body with `**bold**`, `[link](http://x)`, code fences         | Renders bold, clickable link, fenced `<pre><code>`. Link color matches `--accent`.                                 |
| 1.4  | Markdown body with `<script>alert(1)</script>`                         | Script stripped (DOMPurify). Renders as empty `<span>` or nothing.                                                 |
| 1.5  | Markdown body with `<img>` tag                                         | Image renders (DOMPurify allows src/alt). Broken image if URL invalid — no crash.                                  |
| 1.6  | Comment author/body/timestamp field variations (`body` / `text`)       | Renders regardless — defensive field reads (`body || text || content`).                                             |
| 1.7  | Fetch fails (bd missing, or show errors)                               | "Error loading comments: <msg>". Add-comment form still usable.                                                    |
| 1.8  | Very long comment body (> 5 KB markdown)                               | Renders within the modal (scrollable ancestor). No layout overflow.                                                 |
| 1.9  | Comment with special chars (`<`, `>`, `&`, `\n`, backticks)            | Escaped properly via the marked → DOMPurify pipeline. No raw HTML leakage.                                          |
| 1.10 | Reopen a modal on the same bead after a posted comment                 | Re-fetches; new comment appears at the bottom.                                                                      |

## 2. Add-comment form

| #    | Scenario                                                              | Expected                                                                                                           |
|------|-----------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------|
| 2.1  | Click Comment button with empty textarea                               | Inline error: "Empty comment — type something first." Textarea focused.                                            |
| 2.2  | Type "Working on this" and click Comment                               | Log: `addComment id=bd-… bodyLen=15` + `bd comment add … → ok`. New comment appears in the thread.                 |
| 2.3  | ⌘↵ (Cmd+Enter) in textarea                                             | Submits as if the button was clicked.                                                                              |
| 2.4  | Submit a multi-line markdown body with code fences                     | Body piped via stdin to bd; survives unchanged. Renders formatted.                                                 |
| 2.5  | bd returns an error (unknown id, permissions, etc.)                    | Status line shows the error, red. Textarea contents preserved so the user can retry.                               |
| 2.6  | Double-click Submit before first resolves                              | Button disabled after first click; second click is a no-op.                                                        |
| 2.7  | Bridge unavailable (no __nppBridge — can't happen with native host but sanity) | "bridge unavailable" in status line.                                                                        |
| 2.8  | Close modal while Posting…                                             | In-flight `bd comment add` completes in the background; re-opening shows the new comment.                          |
| 2.9  | JSONL-only backend (no bd)                                             | Submit → error in status line: "ReadOnly" equivalent. No crash.                                                    |

## 3. Activity view

| #    | Scenario                                                                | Expected                                                                                                         |
|------|-------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------|
| 3.1  | Switch view popup to "Activity"                                        | `app/activity.html` loads. Heading "Recent activity" + summary "N issues". Rows sorted by updated_at DESC.        |
| 3.2  | Click a row's id link                                                   | Panel switches to Board view, detail modal opens on that bead.                                                   |
| 3.3  | Click anywhere else in the row                                         | Same as (3.2).                                                                                                    |
| 3.4  | Search field typed while on Activity                                    | Rows filter live. Summary becomes "N of M shown".                                                                 |
| 3.5  | Search that matches nothing                                             | Empty state: "No issues match the current search."                                                                |
| 3.6  | Project with 0 beads                                                    | "No issues in this project yet."                                                                                  |
| 3.7  | Project with > 200 beads                                                | Rows capped at 200 most recent. Search narrows to the rest.                                                       |
| 3.8  | Status pill colors match the Board                                      | `App.statusColor` is shared — same greens / reds / etc.                                                           |
| 3.9  | Assignee shown when present                                             | `@alice` appears. Missing assignees show nothing (no empty `@`).                                                 |
| 3.10 | Timestamp format: same day = `HH:MM`, other day = `YYYY-MM-DD HH:MM`    | Matches across rows.                                                                                              |
| 3.11 | Switch to Activity then to Board then back — modal inside Board stays? | Modal state is local to Board page — switching away closes it (Board page unloads).                              |

## 4. "N new" status-bar badge

| #    | Scenario                                                                | Expected                                                                                                         |
|------|-------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------|
| 4.1  | First-ever panel open (no NppBeadsLastActivityVisit stored)             | No badge (we don't stamp on first open; count would be "all issues" — spammy).                                  |
| 4.2  | Visit Activity view once                                                 | Badge clears. Defaults now has an ISO timestamp for this project.                                                 |
| 4.3  | Receive a bd write from an external agent (terminal bd update)          | Within one poll cycle (2 s), status bar updates to `… · ● 1 new`.                                                |
| 4.4  | Two external updates arrive                                             | `· ● 2 new`.                                                                                                     |
| 4.5  | Visit Activity                                                           | Badge disappears. New external update → `· ● 1 new` again.                                                        |
| 4.6  | Switch to a project that has never been visited                          | Badge absent until user visits Activity there once.                                                              |
| 4.7  | Unfocus NPP, agent posts comment/update, refocus NPP                    | _hostWindowBecameKey fires → status bar refreshes → badge visible.                                               |
| 4.8  | Panel in JSONL-only mode + external bd write (no poll)                   | Watcher fires on JSONL change → status bar refreshes → badge visible within the 750 ms debounce.                 |
| 4.9  | Corrupt `NppBeadsLastActivityVisit` defaults                             | Non-dict or non-string entries → treated as "no timestamp" → badge 0. No crash.                                   |
| 4.10 | `defaults delete` the key mid-session                                   | Badge count drops to 0 on next refresh (no stored timestamp).                                                    |

## 5. Integration with earlier phases

| #    | Scenario                                                                  | Expected                                                                                                          |
|------|---------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------|
| 5.1  | Phase 5 ⌘⌥⇧J with the panel on Activity view                              | Panel switches to Board, detail modal opens on the bead.                                                           |
| 5.2  | Live-sync poll fires while the comments thread is open                    | Board refreshes; thread does NOT auto-refresh (comments only refresh on user-posted adds or modal reopen).         |
| 5.3  | Delete an issue that has comments                                         | bd delete cleans up the issue + its comments server-side. Detail modal closes. Activity view loses the row.        |
| 5.4  | Auto-push toggle ON + add a comment                                        | `bd comment add` runs WITHOUT `--sandbox`. Post-commit dolt auto-push attempt. Observable latency if auth unconf.  |
| 5.5  | Project switcher: swap to a different project mid-typing                   | Modal closes on project change (panel rebind). Textarea contents lost — acceptable (no autosave).                |
| 5.6  | source_repo pill + comments thread + dep editor all visible simultaneously | No layout overlap; comments thread lives between dep editor and timestamps.                                        |

## 6. Crash / regression sentinels

| #   | Scenario                                                                     | Expected                                                                                                    |
|-----|------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------|
| 6.1 | Quit NPP while an addComment is in flight                                    | Clean shutdown. bd completes in the background; no zombie bd process once NPP exits (NSTask tied to us).    |
| 6.2 | marked.min.js or dompurify.min.js missing from the bundle                    | Markdown falls back to plain-text rendering (escaped + `<br>` on newlines). No broken HTML.                 |
| 6.3 | Open 10 detail modals in sequence, each with comment submits                 | No memory leak. fetchBead per-modal is bounded (not N²).                                                    |
| 6.4 | `bd show --json` returns unexpected shape (e.g. array vs dict)               | normalizeBead + our defensive reads keep `comments` as `[]`; no throw.                                      |
| 6.5 | Re-open modal during refetch-after-post                                      | Refetch completes, modal shows new comment. No stuck "Posting…" state.                                      |
| 6.6 | Badge math with malformed timestamp in JSONL                                 | That issue skipped (no updated_at or not string) — doesn't inflate the count.                               |
