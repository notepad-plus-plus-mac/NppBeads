# NppBeads — Architecture Reference

Technical notes on how the plugin is wired together. Complements
`ROADMAP.md` (the "what next"), `STATUS.md` (the "where are we"), and
`docs/PHASE3_TEST_MATRIX.md` (the "does it still work").

## Runtime layers

```
┌─────────────────────────────────────────────────────────────────┐
│ Notepad++ host (AppKit)                                         │
│  └── plugin menu: "Show Beads panel" (⌘⌥⇧B)                     │
└─────────────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│ BeadsPanel (NSView)                                             │
│   title bar · view-mode popup · search · status bar             │
│   ┌─────────────────────────────────────────────────────────┐   │
│   │ WKWebView (custom scheme `nppbeads://`)                 │   │
│   │   bridge.js  — request/response layer (reqId Promises)  │   │
│   │   app/*      — native Kanban / future list+detail pages │   │
│   │   viewer/*   — bundled dicklesworthstone Rich viewer    │   │
│   └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│   _ds              : JsonlDataSource    (always present)        │
│   _activeDataSource: BdDataSource | JsonlDataSource             │
│     (upgraded to Bd after probe succeeds; read/write target)    │
│                                                                 │
│   _bdRunner        : BdCommandRunner                             │
│     NSTask wrapper; --sandbox on every call; version + info     │
│     probe on project bind                                        │
└─────────────────────────────────────────────────────────────────┘
                           │                   │
                           ▼                   ▼
                  ┌─────────────────┐   ┌─────────────────┐
                  │ .beads/ folder  │   │  `bd` binary    │
                  │  issues.jsonl   │   │  (via NSTask)   │
                  │  embeddeddolt/  │   │                 │
                  └─────────────────┘   └─────────────────┘
```

## Data-source abstraction

`BeadsDataSource` is a protocol (see `src/BeadsDataSource.h`) with one
read method (`listAllIssuesWithCompletion`, `showIssue:`), a `rawText`
accessor for the JSONL the Web viewer consumes, plus write methods
(`createIssueWith…`, `updateIssue:…`, `closeIssue:…`, `reopenIssue:…`,
`claimIssue:`, `addDependencyFrom…`, `removeDependencyFrom…`).

Two implementations:

| Class             | Backend                                  | Writable | Used when                                              |
|-------------------|------------------------------------------|----------|--------------------------------------------------------|
| `JsonlDataSource` | reads `.beads/issues.jsonl` directly     | no       | bd isn't installed, or probe fails                     |
| `BdDataSource`    | delegates to `BdCommandRunner` (`bd` CLI)| yes      | bd found + `bd info` exits 0 for the project           |

`BeadsPanel` upgrades `_activeDataSource` from Jsonl → Bd on successful
probe. Status bar surfaces which one is active via
`activeDataSource.backendLabel`.

Errors from writes are `NSError`s in `BeadsDataSourceErrorDomain` with
typed codes (`ReadOnly`, `NotFound`, `BlockedByDeps`, `AlreadyClaimed`,
`Cycle`, `Locked`, `BdMissing`, `NotInProject`, `Generic`). For
`BlockedByDeps`, `userInfo[@"blockers"]` carries the parsed id list so
the UI can show a force-close dialog.

## `BdCommandRunner` contract

- **Resolves bd path** by walking `/opt/homebrew/bin`, `/usr/local/bin`,
  `/usr/bin`, `~/bin`, `~/.local/bin`, `~/go/bin`, then `PATH`.
  Notepad++ launched from Finder loses brew paths; that's why the
  built-in list exists.
- **Every invocation prepends `--sandbox`** (global flag, before the
  subcommand). This disables bd's dolt auto-push; without it, every
  call blocks ~23 s on non-interactive git auth failures. That's
  100-200× latency reduction for most users. See commit `7ec1480`.
- **Env set on NSTask:** `BEADS_ACTOR=NppBeads/$USER`,
  `LANG=en_US.UTF-8`, PATH augmented with `/opt/homebrew/bin`,
  `/usr/local/bin`, `/usr/bin`, `/bin` (for any git hooks bd invokes
  internally).
- **stdout/stderr drained in background** via dispatch_async loops so
  outputs >64 KB can't deadlock the pipe. Exit handled via
  `waitUntilExit` then both semaphores.
- **`expectsJson:NO`** escape hatch for `bd version` / `bd info` — they
  emit plain text; JSON-parse failure there would otherwise flip `ok`.
- **Error classification** via regex over stderr + stdout JSON:
  - `blocked by open issues [bd-A, bd-B]` → `BlockedByDeps`, blocker
    ids parsed into `blockerIds`
  - `issue not found` / `no issue with id` / `no issue found` → `NotFound`
  - `already claimed by` / `currently assigned` → `AlreadyClaimed`
  - `cycle detected` / `would create cycle` → `Cycle`
  - `database is locked` / `file lock` → `Locked`
  - `no beads database found` / `no beads configuration` → `NotInProject`
  - `dolt auto-push failed` / `could not read username` → logged as
    **warning**, not error (exit code still determines ok/fail)
- **Error message priority** (for user-visible toast):
  1. stdout JSON `{"error": "..."}` (bd `--json` error path)
  2. Stderr scrape (first line that isn't a permissions/auto-push warning or a warning-continuation line)
  3. `bd exited N` synthetic
- **Cache:** 750 ms for list, 250 ms for show. Invalidated on every
  write. (`BdCacheEntry` per-arg-tuple.)
- **Warning-block tracking in stderr scrape.** bd's permissions warning
  wraps across 2 lines; naive "skip lines starting with `Warning:`"
  misses the continuation. The scraper tracks `inWarnBlock` and skips
  continuation lines (`Run:`, `Hint:`, `- `) until a blank line.

## Bridge protocol (JS ↔ native)

### Outbound (JS → native)

`window.__nppBridge.call(type, payload)` returns
`Promise<{ok, bead?, error?, errorKind?, blockers?}>`. Implementation
lives in `resources/viewer/bridge.js`.

Message envelope:
```js
{
  type:  'updateBead',   // message routing — NOT bd's issue-type flag
  reqId: 'r42_abc',      // auto-generated; used to match responses
  // …payload keys…
}
```

Supported `type` values and payload shape:

| `type`        | Payload                                                                                                | Native handler           |
|---------------|--------------------------------------------------------------------------------------------------------|--------------------------|
| `getJsonl`    | `{}`                                                                                                   | pushes preloaded JSONL   |
| `openExternal`| `{url}`                                                                                                | NSWorkspace openURL      |
| `openBeadDetails` | `{id}`                                                                                              | navigate Rich viewer to `#/issue/<id>` |
| `createBead`  | `{title, issueType?, priority?, description?, labels?}`                                                | `_handleCreateBead`      |
| `updateBead`  | `{id, title?, status?, priority?, issueType?, assignee?, addLabels?, removeLabels?, description?}`     | `_handleUpdateBead`      |
| `closeBead`   | `{id, reason?, force?}`                                                                                | `_handleCloseBead`       |
| `reopenBead`  | `{id, reason?}`                                                                                        | `_handleReopenBead`      |
| `claimBead`   | `{id}`                                                                                                 | `_handleClaimBead`       |
| `depAdd`      | `{dependent, dependency, depType?}`                                                                    | `_handleDepAdd`          |
| `depRemove`   | `{dependent, dependency}`                                                                              | `_handleDepRemove`       |

**Critical:** the envelope's `type` collides with bd's `--type` flag.
The native handlers read `issueType` and `depType` from the payload so
we never pass the message-type string to bd as an issue type. (That bug
caused every drag to fail with `invalid issue type "updateBead"` before
commit `7524427`.)

### Inbound (native → JS)

Native resolves via `window.__nppBridge.resolve(reqId, payload)` called
from `evaluateJavaScript:`. Payload shape:
```js
{ ok: boolean,
  bead?: <full bead object from bd --json>,
  error?: string,
  errorKind?: number,   // BeadsDataSourceErrorCode raw value
  blockers?: string[] } // populated only for errorKind = BlockedByDeps
```

Promise timeout is 15 s — if native never resolves (crash, wedge), the
Promise rejects with `bridge timeout (<type>)` so the UI doesn't hang.

### Broadcast after write success

`_broadcastDataChanged`:

1. `[_activeDataSource invalidateCache]` (wipes bd in-proc cache)
2. `[_ds reload]` (JsonlDataSource re-reads the file on next `rawText`)
3. `[self _refreshStatusBar]`
4. `evaluateJavaScript:` a snippet that assigns fresh JSONL to
   `window.__nppBeadsPreloadedJsonl` and calls `window.__nppApp.reload()`

Step 4 is critical. Earlier versions called `App.reload()` with the
stale document-start-injected global — the in-memory snapshot never
moved. See commit history for the fix.

## Project detection

`BeadsProjectScanner` walks up from the active Notepad++ file looking
for `.beads/`. Finds `issues.jsonl` path and project root. When no
project found, status bar shows `no project · open a file inside a
repo containing .beads/`.

`BeadsWatcher` registers a `DISPATCH_SOURCE_TYPE_VNODE` source on
`issues.jsonl` with `.ATTRIB | .WRITE | .DELETE | .RENAME`. Fires
callback → `[panel reloadData]`. A content-hash gate (`_jsonlBytesLastSeen`)
guards against no-op touches firing 30+ times per second, which was a
real issue with some external tools.

## Web viewer integration

The bundled dicklesworthstone Rich viewer expects to `fetch('./beads.sqlite3')`.
We intercept in `bridge.js` via a monkey-patched `window.fetch`:

1. Request JSONL (either pre-loaded `window.__nppBeadsPreloadedJsonl`
   or async post-message).
2. Parse JSONL → issue rows + dep rows.
3. Build an in-memory SQLite via sql.js (vendor/sql-wasm.wasm, injected
   as a Uint8Array at document-start to dodge WKWebView's file://
   wasm MIME issues).
4. Serialize → Uint8Array → return as a `Response` with
   `Content-Type: application/octet-stream` — the viewer treats it as
   if it came off disk.

sql.js also synthesizes an `issue_overview_mv` view with the columns the
Rich viewer's queries expect (pagerank/betweenness placeholders, dep
counts computed via correlated subqueries over `dependencies`). Graph
metrics are 0 placeholders — Phase 1 doesn't run the Rust graph engine.

## `nppbeads://` URL scheme

Registered via `WKURLSchemeHandler` so all page loads are same-origin.
Otherwise WKWebView treats individual `file://` resources as separate
origins and refuses ES-module dynamic imports / `WebAssembly.
instantiateStreaming` with a MIME mismatch. `nppbeads://viewer/...`
resolves to files under `resources/viewer/` with correct Content-Type
headers set by extension.

## Reference external docs

- Beads CLI contract snapshot: `memory/nppbeads_phase3_cli_contract.md`
  (compiled from `/Users/leto/development/github/gastownhall/beads/docs/`)
- Phase 3 manual regression: `docs/PHASE3_TEST_MATRIX.md`
- Roadmap through v1.0.0: `ROADMAP.md`
