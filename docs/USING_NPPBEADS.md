# NppBeads

A guide to running issue tracking inside Notepad++ on macOS, with
notes on why the underlying tracker (Beads) is shaped the way it
is and why that shape solves a problem that nothing else really
does: keeping AI coding agents from forgetting what they were
working on.

## The agent memory problem

If you've worked with a coding agent for more than an afternoon,
you've watched it run out of context. The agent fills its window
with tool calls, file reads, intermediate plans, then triggers a
"compaction" step that summarizes the older parts of the
conversation into a few sentences and frees the rest of the
window for new work. The summary is necessarily lossy. After two
or three rounds of this, the agent doesn't remember why it
started the refactor, which file it was waiting on a teammate to
finish, or that the first attempt at the cache fix introduced a
subtle race condition it noted but never tracked. It's gone.
Conversation history compresses; institutional knowledge with
it.

The Gas Town team, who build Dolt and now use coding agents for
real production work, named this directly in their April 2026
blog post: "when coding agents compress the conversation history,
they forget things." Their fix is an issue tracker designed for
exactly this: somewhere outside the conversation window where the
agent persists what it needs to remember. They named it
[Beads](https://github.com/gastownhall/beads). Their description
is the cleanest framing I've seen. "It's like a business storing
information in a Jira ticket. It's institutional memory." Beads
is institutional memory for the agent, the same way Jira is
institutional memory for a company.

Once you say it that way, the design follows from it. The agent
needs structured persistence (not a chat log). It needs to be
queryable in the moment ("what was I about to do next?") and over
time ("why did I add this branch six weeks ago?"). It needs to
survive context compactions, machine reboots, agent restarts, and
team handoffs. It needs to live where the code lives, because the
code is the artifact the memory is about. And it needs to be
accessible to anything that can spawn a subprocess, because
agents talk to the world by spawning subprocesses, not by signing
in to web apps.

If you've been reaching for Jira or Linear or GitHub Issues to
fill this role, you've probably noticed the seams. Those tools
are built for humans clicking through a web UI. Wiring an agent
into them means OAuth flows, scoped tokens, rate limits,
webhooks, and a third party that can be down when you need it
most. Worst of all, the issues live somewhere else from the code,
which means an agent that loses connectivity also loses its
working memory.

## What Beads is

Beads takes the obvious step. It puts the issues in your repo,
specifically in a `.beads/` directory at the root, alongside
`.git/`. The data store is [Dolt](https://www.dolthub.com/),
which is SQL with versioning baked in: PostgreSQL crossed with
git. Every row change is a commit, you can branch the data, diff
between branches, merge them, bisect history. Issues become
real structured data (not markdown files, not YAML), versioned
the same way the code is.

You drive Beads with a command line tool called `bd`. The whole
surface is a CLI:

```sh
$ bd create "Fix cache eviction race" -t bug -p 1 -l backend
Created bd-a3f8

$ bd update bd-a3f8 --status in_progress --assignee alice

$ bd dep add bd-a3f8 bd-b1
# bd-a3f8 now declares it depends on bd-b1.
# Equivalently: bd-b1 blocks bd-a3f8.

$ bd ready
# Returns only issues that are open AND have no
# unresolved blockers. The "what can I actually do
# right now" set.

$ bd comment add bd-a3f8 --body-file=- <<'EOF'
First attempt swapped the global mutex for a per-page
lock. Tests pass but I'm seeing a 3% regression on the
hot path. Trying a different approach tomorrow.
EOF

$ bd close bd-a3f8 --reason "merged in commit a1b2c3d"
```

There's no service. No login. No monthly bill. The first time you
set up a project you run `bd init` and a `.beads/` directory
appears. From then on, the issues travel with the code. Clone
the repo on a new machine, the issues come with it. A
contributor opens a pull request from a fork, you can see the
issues their branch added or modified. Want to back everything
up, copy the repo. Want to roll back to last Tuesday, `git
checkout` last Tuesday and the tracker rolls back too.

For an agent, the same surface is exactly what's needed. The
agent's memory now has a place to live that survives compaction.
Mid-task, it can `bd update --status` to mark progress, `bd
comment add` to record a finding, `bd create` to file a follow-up
it noticed but isn't ready to fix. After compaction wipes its
short-term memory, it can `bd show` whatever it was working on
and reconstruct context from a structured record instead of from
its own summarized chat log. Status and discoveries persist. The
forgetting problem doesn't go away; the agent just has somewhere
durable to put things before they get summarized into oblivion.

```
┌────────────────────────────────────────────────────────────────┐
│                                                                │
│                                                                │
│                                                                │
│   📷  Hero shot. Notepad++ on macOS with a code file open on   │
│       the left and the NppBeads panel docked on the right      │
│       showing the Board view with a few cards visible.         │
│                                                                │
│                                                                │
│                                                                │
└────────────────────────────────────────────────────────────────┘
```

## The agent loop in practice

Concretely, an agent driving a piece of work through Beads looks
like this:

```sh
# What is actionable right now?
bd ready --json

# Take the first one atomically. --claim sets
# assignee + status=in_progress in one transaction
# and refuses if someone else already claimed it.
bd update bd-a3f8 --claim --json

# ... do work. Commit. Run tests.

# Note progress, attaching commit context.
bd comment add bd-a3f8 --body-file=- <<'EOF'
Refactored the cache to use a per-page mutex instead
of the global lock. Tests pass. Open question on whether
to backport to v1.x; filed bd-c2 to track it.
EOF

# Done.
bd close bd-a3f8 --reason "merged in #1234"
```

Five subprocess calls, no auth, no rate limits, no third-party
outage mode. The whole exchange runs at local-SQL-query latency.
And every one of those calls produces a Dolt commit, so an agent
that compacts its conversation an hour later can run `bd show
bd-a3f8` and read back exactly what it did, when, and why.

## Why the dependency graph matters

Beads's dependency graph is more than convenience. It supports
ten relationship types, not just one: `blocks`, `parent-child`,
`conditional-blocks`, `waits-for`, `related`, `tracks`,
`discovered-from`, `caused-by`, `validates`, and `supersedes`.
That vocabulary is enough to describe real engineering shape: a
child issue under an epic; a blocker that only applies under a
specific condition; a follow-up that was discovered while fixing
something else; a validation issue that confirms an earlier fix
held.

For an agent picking what to work on next, this matters
enormously. `bd ready` doesn't just check direct blockers; it
walks the whole graph and returns only issues that are genuinely
unblocked under the current state. An issue with a `waits-for`
dependency on a closed issue becomes ready the moment the closure
commits. A child issue won't show as ready until its parent is
done. The agent gets a clean answer to "what should I do next"
without writing its own graph traversal.

The graph also unlocks analytic primitives that would otherwise
take real engineering to build. `bd` (and the NppBeads Graph view
that wraps it) compute PageRank to surface structurally important
issues, betweenness centrality to identify bottleneck issues that
bridge otherwise-independent work clusters, critical path through
the DAG, cycle detection, and other graph-theory standards. None
of these are decoration. "Give me the five issues with the
highest PageRank that are currently ready" is a useful question
with a clean answer when an agent is grinding through a hundred
issue backlog without human supervision.

## Beads as an agents orchestrator

It's tempting to describe Beads as "just an issue tracker with
good agent affordances," but that undersells it. In practice,
when you have more than one agent — or even one agent plus a
human — working the same backlog, Beads starts doing the work
of a lightweight orchestrator. Not in the heavyweight
workflow-engine sense. In the "shared ledger that coordinates
independent workers" sense. If you've used a job queue or a
pub/sub broker, the mental model is the same; the queue is the
dependency graph, and the workers are whoever can spawn a
subprocess.

A point worth making up front, because it changes how you
think about the whole tool: in a Beads-driven workflow, **most
of the writing and most of the reading is done by agents, not
humans**. Humans file the load-bearing issues — epics,
high-priority bugs the agent can't be trusted to scope on its
own, decisions that need a person to weigh in. Agents do
everything else: they file the follow-ups they discover mid-
work, they comment progress, they update statuses, they claim
work, they close work. A typical project's `bd log` will be
ninety-percent agent activity and ten-percent human, and that's
the design target, not an accident. NppBeads is mostly a
window onto agent activity that happens to also let humans
participate in it. If you're coming from Jira where humans
write everything by hand, that inversion is the biggest
mental adjustment.

A few things make this more than an analogy.

**Atomic claim semantics.** `bd update --claim` sets
assignee + status=in_progress in one transaction and refuses if
something else already claimed the issue. Two agents starting
from the same `bd ready` snapshot will both try to claim the
top of the list; exactly one wins. The other reads the
conflicting state back, re-runs `bd ready`, and grabs a
different item. No coordinator, no lock service — Dolt's
single-writer semantics at the repo level do the job. This is
the equivalent of an at-most-one-consumer queue, for free.

**Dependency-aware dispatch.** `bd ready --json` doesn't just
return unassigned issues. It walks the full dependency graph
and returns only issues whose blockers (of every type — `blocks`,
`parent-child`, `waits-for`, `conditional-blocks`) are
resolved. An agent reading from `bd ready` will never pick up
work that can't actually be done yet. For orchestration, this
means you can file a hundred issues at once with the real
dependencies between them and let agents consume the queue in
topological order without you having to schedule anything.

**Handoff patterns.** When an agent closes an issue that
unblocks another agent's work (its blocker-in-waiting becomes
ready), the next `bd ready` call from the second agent picks it
up naturally. No webhook, no signal, no retry loop. The second
agent just asks "what can I do now" and gets a new answer. A
team of three agents running on a two-second `bd ready` poll
behaves as a self-scheduling worker pool — each claims what it
can, moves on when blocked, comes back when unblocked. You
watch the Kanban board in NppBeads fill with in-progress cards
and drain into closed without ever telling any of them to do
anything.

**Discovery propagation.** When an agent mid-work discovers a
follow-up ("this fix exposed a second bug in the auth
middleware"), it files a new issue with a `discovered-from`
dependency back to the one it's working on. The graph grows
organically. Other agents see the new item next time they poll.
Humans reviewing the project three days later can trace every
discovered-from chain back to the originating work. This is
what a real orchestrator would call lineage tracking, and it
emerges from the dependency vocabulary without any specific
feature.

**Review and rollback.** Because the whole store is in Dolt and
Dolt is in the repo, the orchestration log is a git log. `git
log .beads/` is a chronological trace of every claim, every
status change, every comment, every dependency add. `git
blame` on a closed issue tells you which agent closed it and
when. If an afternoon of agent work produced bad results, `git
revert` on the relevant range of Dolt commits rolls the whole
tracker state back atomically — and the code it was working on
rolls back in the same operation. I don't know of another
tracker where you can undo six hours of automated work that
cleanly.

```
┌────────────────────────────────────────────────────────────────┐
│                                                                │
│                                                                │
│   📷  Terminal on the left running three `bd ready --claim`    │
│       loops in parallel (three "agents"), with NppBeads's      │
│       Board view on the right showing cards moving from        │
│       Open → In Progress → Closed in real time. Status bar     │
│       showing "● 12 new" ticking up.                           │
│                                                                │
│                                                                │
└────────────────────────────────────────────────────────────────┘
```

NppBeads is where this stops being abstract. With the panel
open, you can watch an orchestrated run happen live: cards
moving across columns, the Activity feed filling in
reverse-chronological order, the status-bar "● N new"
indicator counting updates you haven't looked at yet, the
Graph view's particles changing direction as dependencies
close. For the first time I've felt like I had proper
observability over a fleet of agents, and everything I'm
watching is the same data the agents themselves are operating
on. There's no separate "agent dashboard" to keep in sync with
reality; the dashboard is the data.

## Why this is not Jira

Beads gets compared to Jira often, and the comparison is half
right. Both are issue trackers. Both have hierarchical
relationships, statuses, comments, custom fields. Both are how
work gets coordinated.

The differences are what make Beads work for agents:

- Jira's data lives on Atlassian's servers. Beads's data lives in
  your repo. An agent without internet still has Beads.
- Jira is accessed through OAuth-protected REST APIs with rate
  limits. Beads is accessed by spawning a subprocess. An agent
  that can run a build can use Beads.
- Jira's history is one-way: tickets accumulate, the audit log
  grows, but there's no checkout-Tuesday operation. Beads is in
  Dolt, so every state of the tracker is a commit you can roll
  back to or branch from.
- Jira's permissions and workflow engine assume humans. Beads
  assumes anything that can read a JSON document and parse a
  result code.

For a team of humans, Jira and Linear and GitHub Issues are fine
and probably better. They have nicer mobile apps. For a team of
humans plus one or more agents working through a backlog while the
humans sleep, Beads is the artifact that keeps the agents
coherent. The Dolt team's framing fits: institutional memory, but
for the agent.

One last point worth saying before getting into the plugin.
Because Beads is in Dolt and Dolt is in the repo, every action an
agent takes is also a git commit you can review. `git log
.beads/` is a chronological tour of what the agent did. `git
blame` on a status change tells you which agent changed it and
when. Reverting a bad afternoon of agent activity is the same
operation as reverting bad code: identify the commits, `git
revert`, and the tracker rolls back with the code. Few SaaS
trackers offer anything close.

## Running this for a team (and replacing Jira)

A common reaction to the agent-orchestrator framing is "fine,
that works for one developer with a couple of agents on one
laptop. What about a real team across multiple machines? What
about the existing Jira instance with eight years of history
in it?" Both answers are good, and worth covering concretely
because they're the difference between "interesting toy" and
"thing you can deploy at work."

### Two humans, two NppBeads, one project (single machine or shared filesystem)

The simplest team setup is two or more developers working out
of the same repo on the same machine, or out of a shared
filesystem (NFS, SMB, even a synced Dropbox/iCloud folder if
you're feeling brave). Each runs Notepad++ with NppBeads
installed. Each binds the panel to the same project root.
That's it. Both panels point at the same `.beads/issues.jsonl`,
both panels watch it for changes, both panels poll `bd` every
two seconds. When developer A drags a card from Open to In
Progress, developer B's panel reflects it within two seconds.
When developer B's agent posts a comment, developer A sees the
status-bar `● N new` indicator tick up.

The same goes for one human plus N agents on the same machine.
The agents run in their own terminals (or under a process
manager — `tmuxp`, `pm2`, `systemd --user`), all calling `bd`
against the same `.beads/`. NppBeads watches the resulting
churn. You don't tell the panel about the agents and you don't
tell the agents about the panel; they all just talk to `bd`.

Single-machine multi-writer is handled by Dolt's embedded mode
(the default after `bd init`) up to a point — concurrent writes
from the same process are fine, but truly parallel writers from
different processes can collide. For a small team or a couple
of agents this is rare enough not to matter. When it does
matter, you switch to server mode (next subsection).

### Multi-writer mode for one team on one machine

When you start running multiple agents in parallel and they
trip over each other on writes, switch to Dolt server mode:

```sh
bd init --server                 # initial setup, or
export BEADS_DOLT_SERVER_MODE=1  # for an existing project
```

Server mode runs `dolt sql-server` as a separate process
exposing two ports — MySQL (3306) for SQL access, and
remotesapi (8080) for peer sync. Every `bd` invocation, from
every agent, from every NppBeads panel, talks to that server.
Concurrent writes are serialized through Dolt's transactional
layer instead of through file locks. There's no central
permission service; the server runs as your local user, agents
run as your local user, and Dolt sorts the writes out.

Practically: if you can have five agents grinding through a
backlog at full tilt without seeing `bd` errors, you don't
need server mode. If you start seeing transient lock errors,
flip the switch. NppBeads doesn't care which mode you're in —
it spawns `bd` the same way either way.

### Multiple machines, multiple humans, multiple NppBeads instances (federation)

This is where Beads gets interesting compared to Jira. Each
machine, or each office, runs its own Dolt-backed Beads. They
sync to each other peer-to-peer using **federation** — Dolt's
distributed-version-control facility, the same mechanism that
makes Dolt itself a "Git for SQL." There is no central server
in the architectural sense; each town (Beads's term for a
participating workspace) is autonomous and can keep working
during a network partition.

Setup looks like adding a remote to git. From inside the
project, on each participating machine:

```sh
# Register a peer (one-time, per peer, per machine)
bd federation add-peer team-alpha dolthub://my-org/beads
bd federation add-peer team-beta  ssh://team-beta.example.com/srv/beads
bd federation add-peer backup     s3://my-bucket/beads-backup

# Sync (run on demand, or scheduled via cron / launchd / systemd timer)
bd federation sync
```

Endpoints can point at DoltHub (Dolt's hosted Git-for-data
service), an SSH host running `dolt sql-server`, an S3 or GCS
bucket, an HTTPS server, or a local file path on a network
share. Push/pull happens at Dolt's row-merge granularity, not
file-diff, so two teams editing different fields of the same
issue don't collide. When real cell-level conflicts do happen
(both sides changed the same field on the same row), `bd
federation sync` either pauses for manual resolution or
auto-resolves with `--strategy ours` / `--strategy theirs` if
you want unattended sync.

For three offices in three time zones each running multiple
agents and a handful of humans with NppBeads, the topology
looks like:

```
┌─────────────────┐       ┌─────────────────┐       ┌─────────────────┐
│   Office NYC    │ <-->  │   Office BLR    │ <-->  │   Office LON    │
│ ─────────────── │       │ ─────────────── │       │ ─────────────── │
│ Local Dolt sql- │       │ Local Dolt sql- │       │ Local Dolt sql- │
│ server          │       │ server          │       │ server          │
│   :3306 SQL     │       │   :3306 SQL     │       │   :3306 SQL     │
│   :8080 sync    │       │   :8080 sync    │       │   :8080 sync    │
│                 │       │                 │       │                 │
│ N humans w/     │       │ N humans w/     │       │ N humans w/     │
│  NppBeads       │       │  NppBeads       │       │  NppBeads       │
│ M agents        │       │ M agents        │       │ M agents        │
└─────────────────┘       └─────────────────┘       └─────────────────┘
```

Each office writes to its own local server (low latency, no
internet round-trip, works offline). A cron job in each office
runs `bd federation sync` every ten minutes. The Dolt commit
graph fans out and back in across all three offices like a
distributed git repo. NppBeads users see remote-team activity
appear during the next sync cycle plus their own two-second
poll — so worst case, an issue closed in NYC at 09:00 shows up
on a BLR developer's NppBeads panel within ten or twelve
minutes. For most team workflows that's plenty fast; for the
few times it isn't, an on-demand `bd federation sync` from
either side takes seconds.

```
┌────────────────────────────────────────────────────────────────┐
│                                                                │
│                                                                │
│   📷  Two NppBeads windows open side-by-side, one labeled      │
│       "NYC dev" and one "BLR dev", both bound to the same      │
│       project. NYC has just dragged a card to In Progress;     │
│       BLR's panel shows the same card moved to In Progress     │
│       a moment later, with the activity badge incremented.     │
│                                                                │
│                                                                │
└────────────────────────────────────────────────────────────────┘
```

Sovereignty tiers (T1 through T4) let you mark which issues
are allowed to leave a region. T1 means no restriction; T4
means the issue stays purely local and is never pushed to any
peer. For organizations that have to juggle GDPR or other
regional-data rules, the tier mechanism does that without
running a separate replication broker.

### Bridging to Jira, GitHub, Linear, GitLab, Azure DevOps, Notion

If your organization already lives in one of those, Beads can
treat it as another peer. The `bd <tracker> sync` family of
commands do bidirectional sync over the tracker's REST/GraphQL
API:

```sh
# One-time configuration
bd config set jira.url      "https://acme.atlassian.net"
bd config set jira.project  "PROJ"
bd config set jira.username "alice@acme.com"
bd config set jira.api_token "$JIRA_TOKEN"

# Sync (typically run on a cron / launchd schedule)
bd jira sync                           # bidirectional: pull then push
bd jira sync --pull                    # one-way import
bd jira sync --push --create-only      # only create new in Jira
bd jira sync --prefer-local            # local wins on conflicts
bd jira sync --prefer-jira             # remote wins on conflicts
bd jira sync --dry-run                 # preview, change nothing
```

`bd github sync`, `bd linear sync`, `bd gitlab sync`, `bd ado
sync`, and `bd notion sync` follow the same shape with their
own configuration keys. All of them go through `bd`, so any
sync that runs from a terminal also reflects in NppBeads
panels within the next refresh cycle. Conflict resolution
defaults to "newer timestamp wins" with the same `--prefer-*`
overrides everywhere.

The pragmatic substitute-for-Jira deployment looks like:

1. Keep your Jira instance for the things Jira is good at:
   long-lived strategic projects, formal release management,
   stakeholder reporting, anything that needs a person logging
   in to a polished web UI.
2. Run Beads with NppBeads as the day-to-day surface for the
   engineering team and the agents that work alongside them.
   Most issues live and die in Beads without ever touching
   Jira.
3. Set up `bd jira sync` (with `jira.push_prefix` configured
   to limit what gets pushed) to bubble a curated subset up
   to Jira on a fifteen-minute schedule, so PMs and execs see
   what they need without anyone hand-typing tickets.

This is the same pattern teams used to bridge Jira and
GitHub Issues for years. The difference is that Beads's
"local side" of the bridge is a fully-versioned database the
agents can write to at thousands-of-issues-per-second
throughput, not a SaaS API with rate limits — so the
bridge stops being the bottleneck.

```
┌────────────────────────────────────────────────────────────────┐
│                                                                │
│                                                                │
│   📷  Diagram: Jira instance on the left, three federated      │
│       Beads "towns" on the right (NYC / BLR / LON), `bd        │
│       jira sync` arrows running between Jira and one of        │
│       the towns. Per-tracker sync arrows annotated with the    │
│       command that does each one.                              │
│                                                                │
│                                                                │
└────────────────────────────────────────────────────────────────┘
```

### A note on access control and audit

Beads inherits its access model from the filesystem and from
the Dolt server's MySQL auth. Reading and writing the local
`.beads/` is whoever has the unix permissions on it. Reading
and writing through a federated Dolt server is whoever has
SQL credentials. There's no built-in role/permission system —
that's a feature for the use cases Beads targets (small
teams, agent fleets, code repos), and a missing feature for
"replace Jira at a 5,000-person org with department-level
access controls." For the latter, run Beads inside the trust
boundary of the team that owns the code, sync up to Jira for
broader visibility, and let Jira's permission system enforce
who-sees-what at the corporate scale.

For audit, every `bd` write attributes itself to an actor
(set via the `BEADS_ACTOR` env var, the `--actor` flag, or
falling back to git's `user.name`). Every write becomes a
Dolt commit in the workspace's history. Federation pushes
that commit history across peers, so the trail is global, not
local. `git blame` and `git log` on `.beads/` answer "who did
what when" at the same fidelity they answer the same question
about source code.

## What NppBeads is, exactly

NppBeads is a Notepad++ plugin that puts a Beads UI inside the
editor. The "UI" is a docked side panel containing a webview that
shows six different surfaces (Dashboard, Issues list, Insights,
Graph, Kanban Board, Activity feed), all driven by `bd` calls
under the hood.

Practically, this means the plugin is a thin wrapper. Every read
goes through `bd list --json`, `bd show --json`, etc. Every write
goes through `bd create`, `bd update`, `bd close`, `bd comment
add`, and friends. There's no NppBeads database, no syncing
process, no caching beyond what `bd` itself does. If you do
something via NppBeads, the next person who runs `bd list` from a
terminal will see it. If a teammate's agent does `bd update` from
a script, your panel will refresh within two seconds.

That hard rule (everything is `bd`) means NppBeads doesn't lock
you in. You can use it for the morning, switch to a terminal in
the afternoon, let an agent run overnight, come back the next
morning, and there's no merge conflict because there was nothing
to merge. The single source of truth is whatever `bd` says, and
NppBeads is one of several front ends.

The plugin exists for the same reason most editor plugins exist:
to remove a context switch. The cost of dropping out of NPP into
a terminal to run `bd update` is small individually but
multiplicative across a day. After a couple of weeks of
maintaining beads via terminal, I caught myself just not updating
statuses anymore. The friction had won. NppBeads is the result of
deciding that wasn't acceptable.

## Installing it

The deliverable is a zip containing a single dylib and a bundle
of HTML, JS, CSS, and font assets that the panel renders inside
WKWebView. To install, unzip into the standard plugins directory:

```
~/.notepad++/plugins/NppBeads/
├── NppBeads.dylib       # the plugin itself
├── toolbar.png          # toolbar icon
└── resources/
    └── viewer/...       # bundled UI assets
```

Restart Notepad++. The plugin shows up under `Plugins → NppBeads`
with three menu items at first (Show Beads panel, Reload issues,
Reveal .beads/ in Finder) and a few more once you've used it
(Jump to bead under caret, Copy bead id, Create issue from
selection). The default keyboard shortcut for opening the panel
is Cmd-Option-Shift-B; if that conflicts with anything in your
setup, rebind via the standard NPP shortcut manager.

For editing to work, you also need the `bd` CLI on your `PATH`.
Homebrew is the easiest source:

```sh
brew install beads
bd version   # confirms install
```

Without `bd`, the plugin still runs, but in read-only mode: it
reads `.beads/issues.jsonl` (the export file Beads automatically
maintains for compatibility) and shows you the data, but every
edit attempt fails with a "ReadOnly" error. The status bar at the
bottom of the panel shows whether you're in `bd` mode (`bd
v1.0.2` or similar) or JSONL fallback mode (`read-only (JSONL)`).

If you launch NPP from Finder rather than from a terminal, NPP
inherits a sparse `PATH` that often doesn't include
`/opt/homebrew/bin`. NppBeads handles this by checking a list of
common install locations directly (`/opt/homebrew/bin`,
`/usr/local/bin`, `~/bin`, `~/.local/bin`, `~/go/bin`) before
falling back to the inherited `PATH`. So `brew install beads`
followed by a NPP relaunch should just work, no shell setup
required.

## The first time you open it

Open the panel with Cmd-Option-Shift-B (or Plugins → NppBeads →
Show Beads panel). You land on the Dashboard view by default.

If you currently have a file open that lives anywhere inside a
Beads project (the panel walks up from the file's directory
looking for a `.beads/` sibling, stopping at your home folder),
the plugin auto-binds to that project. The status bar shows the
project name, issue counts (open, blocked, closed, total), and
the backend mode.

If no file is open, or the active file is in a directory that
isn't part of a Beads project, you see "(no project) ▾" where the
project name would be and a status hint telling you to click the
project name to pick one.

```
┌────────────────────────────────────────────────────────────────┐
│                                                                │
│                                                                │
│   📷  The panel toolbar with the project switcher dropdown     │
│       open. Shows the checkmarked current project at the top   │
│       plus a list of recent projects, plus the "Open .beads    │
│       folder…" entry at the bottom, plus "Unbind current       │
│       project."                                                │
│                                                                │
│                                                                │
└────────────────────────────────────────────────────────────────┘
```

The switcher dropdown is the project name itself, with a small
chevron after it. Click it to pick from a few sources:

* The project you currently have bound, with a checkmark.
* Recent projects you've opened before. The list is persisted
  across NPP launches via NSUserDefaults, capped at the ten most
  recent. If a recent project's `.beads/` directory has been
  deleted since you last touched it, the entry is filtered out
  silently.
* "Open .beads folder…" which opens a file picker. Useful when
  you want to point at a project without having a file from it
  open in NPP.
* "Unbind current project" if you want the panel to forget what
  it's bound to (e.g. you're about to close the project entirely).

One small UX note about the switcher: if you've manually bound
project A via the picker, then open a file from project B, the
panel switches to B. The most recent action wins. If that's not
what you want, pick A again from the switcher and don't open
files from B until you're done.

## A tour of the six views

The view popup in the toolbar (next to the project name) toggles
between six different surfaces. They overlap intentionally;
different angles on the same data for different moods.

### Dashboard

The Dashboard is the start screen. It shows the things that
matter when you're trying to figure out where the project is
overall: total issue counts split by status (Open, In Progress,
Blocked, Closed), top "AI Priority Picks" (issues ranked by an
internal greedy unblock score), distribution charts by type and
priority, recent activity summary.

I open the panel cold, glance at the Dashboard for two seconds,
and either keep going (everything's normal) or notice that the
blocked count jumped overnight (which is when I switch views).

```
┌────────────────────────────────────────────────────────────────┐
│                                                                │
│                                                                │
│   📷  Dashboard view on a mid-size project (80-ish issues).    │
│       Four stat cards across the top (Open / In Progress /     │
│       Blocked / Closed with counts), "AI Priority Picks"       │
│       list below, two distribution donuts (by type, by         │
│       priority) at the bottom, recent activity strip.          │
│                                                                │
│                                                                │
└────────────────────────────────────────────────────────────────┘
```

### Issues

The Issues view is the flat searchable list. This is where you
go when you remember "there was a bug about the cache, something
about a race condition," and need to find it. Type into the
search field at the top of the panel; the list filters live
across the issue id, title, and description. Behind the scenes
it tries an FTS5 full-text index first and falls back to a LIKE
query on the same fields if FTS doesn't find anything (which
catches substring matches that FTS's word-prefix matching
misses).

A second row of filters lets you narrow by assignee, status,
priority, label, sort order, blocked / not-blocked, blocking /
not-blocking. The combination of search query plus filters is
sticky across navigations within the panel, so you can click
into an issue's detail, come back, and the list is still where
you left it.

The list paginates a hundred at a time. For projects with more
than a hundred issues, controls at the bottom let you walk
through pages. For most projects under a hundred, you'll see
everything on one page.

```
┌────────────────────────────────────────────────────────────────┐
│                                                                │
│                                                                │
│   📷  Issues view with a search term typed in ("cache") and    │
│       two filter chips active ("Status: open", "Priority:      │
│       P1"). List below shows matching rows with blue-          │
│       highlighted search hits in title/description, priority   │
│       pills on the left, status pill on the right.             │
│                                                                │
│                                                                │
└────────────────────────────────────────────────────────────────┘
```

### Insights

Insights is the analytics surface. Top by PageRank, top by
betweenness centrality, top by critical path depth, k-core
analysis, articulation points (issues whose removal would
disconnect the dependency graph), cycles (if any), and several
other graph-derived rankings.

The numbers come from a small WebAssembly graph engine bundled
with the panel that runs the algorithms over the dependency
edges. For a hundred-issue project the whole thing computes in a
few hundred milliseconds, recomputed automatically when the
data changes.

This is the view I open least often, but when I do open it, it's
because I want a structural answer to a structural question:
"what's the most load-bearing issue in this project right now?"
Insights answers it.

```
┌────────────────────────────────────────────────────────────────┐
│                                                                │
│                                                                │
│   📷  Insights view showing the top panels: "Top by            │
│       PageRank" (five-ish rows with id, title, and a numeric   │
│       score), "Top by Betweenness" below, and an               │
│       Articulation Points panel to the right listing two or    │
│       three bead ids whose removal would disconnect the graph. │
│                                                                │
│                                                                │
└────────────────────────────────────────────────────────────────┘
```

### Graph

The Graph view is the dependency graph rendered as a
force-directed layout, with all the visual affordances you'd
expect: hover for highlights, click for details, zoom and pan,
drag to reposition, color-coded nodes, animated particles
flowing along edges. There's a lot to say about this view; it
has its own section further down.

```
┌────────────────────────────────────────────────────────────────┐
│                                                                │
│                                                                │
│                                                                │
│   📷  Graph view in light mode, with maybe twenty nodes        │
│       visible, one node hovered to show its connected          │
│       subgraph highlighted in gold, the Display panel          │
│       visible on the right showing the layout dropdown.        │
│                                                                │
│                                                                │
│                                                                │
└────────────────────────────────────────────────────────────────┘
```

### Board

The Board is the kanban surface. Four columns by default: Open,
In Progress, Blocked, Closed. Each card is an issue, drag a card
to a new column, that column's status is committed via `bd
update --status`. Optimistic UI: the card moves immediately, and
either confirms (toast) or rolls back (toast plus original
position) depending on what `bd` reports.

```
┌────────────────────────────────────────────────────────────────┐
│                                                                │
│                                                                │
│   📷  Board view with a card mid-drag from "In Progress" to    │
│       "Blocked", visibly held by the cursor. Other cards       │
│       visible in their columns underneath.                     │
│                                                                │
│                                                                │
└────────────────────────────────────────────────────────────────┘
```

There's a **Raw / Effective** toggle in the top-left header of
the Board. It changes which column each card lives in without
touching the underlying data, and it's worth understanding why
the distinction exists.

`bd` does not automatically rewrite an issue's stored `status`
when one of its blockers opens or closes. That's a design
choice: "status" is the value you last committed ("I wrote this
down as in_progress"), and the blocked-by-the-graph state is
something the tracker computes on the fly from the dependency
edges. Two different facts about the same issue, both useful.

* **Raw** groups by the stored `status` field exactly as bd
  wrote it. A card is in the Blocked column only if you (or an
  agent, or a teammate) explicitly called `bd update --status
  blocked` on it. This is the manual-data view: what does the
  database actually say.
* **Effective** adds one rule on top: any open or in-progress
  card that has at least one non-closed blocker dependency gets
  promoted into the Blocked column, regardless of what its
  stored status says. This is the view that matches what `bd
  ready` returns — the actually-actionable set — and what you
  mean when you ask out loud "what's blocked right now."

I leave Effective on most of the time because that's the
question I'm usually asking. I switch to Raw when I'm auditing
the data itself: "which cards did someone actually flag as
blocked manually, and are any of those stuck labels stale?"
Toggling between them on the same board makes the discrepancies
jump out visually — a card that sits in Open under Raw and
Blocked under Effective is one whose dependency graph is ahead
of its manual status, and usually the manual status is what
needs updating.

```
┌────────────────────────────────────────────────────────────────┐
│                                                                │
│                                                                │
│   📷  Board view with the Raw / Effective toggle visible at    │
│       the top, Effective selected. Two cards that look         │
│       "Open" under Raw have shifted into the Blocked column    │
│       here — a subtle outline treatment distinguishes them     │
│       from cards whose stored status literally is "blocked."   │
│                                                                │
│                                                                │
└────────────────────────────────────────────────────────────────┘
```

The "+ New issue" button in the top-right opens a modal where
you can fire off a new issue without leaving the panel. Title,
type, priority, labels, description (Markdown), plus two
chip-input fields for declaring blocked-by and blocks
relationships at creation time. Each chip can be tagged with one
of the ten Beads dependency types.

### Activity

Activity is the reverse-chronological feed. Issues sorted by
their `updated_at` timestamp, descending. Each row shows the id,
title, status pill, priority pill, assignee, last-updated time.

```
┌────────────────────────────────────────────────────────────────┐
│                                                                │
│                                                                │
│   📷  Activity view with one row hovered/expanded showing the  │
│       inline preview: description excerpt, type, labels,       │
│       blocked-by/blocks counts, source repo if any. The        │
│       "Open ↗" button visible on the right of that row.        │
│                                                                │
│                                                                │
└────────────────────────────────────────────────────────────────┘
```

Hover any row and it expands inline with a preview block:
description excerpt (first six hundred characters of the
Markdown source, with a fade mask if truncated), type, labels,
blocked-by count, blocks count, source repo if any.

The view is deliberately read-only on click. Nothing in a row
will navigate you to the Board's detail modal except the "Open
↗" button on the right side, which only appears when you hover.
This is so you can scan the feed without your finger
accidentally landing somewhere that pulls you into an editing
flow you didn't ask for.

The Activity view also drives the "● N new" indicator in the
status bar. Every time you visit the Activity view, the panel
records the current timestamp. Subsequent updates that happen
after that timestamp (from your own edits, agents, teammates)
get counted in the badge. Visiting Activity again resets the
counter. Quitting and reopening NPP preserves the count
correctly across sessions.

## Creating and editing issues

The detail modal is the workhorse. You get to it three ways:

1. Click any card on the Board.
2. Click the "Open ↗" button on any Activity row.
3. Use Cmd-Option-Shift-J on a `bd-XXX` reference in your code
   (more on that further down).

What you see is a single dialog with every field of the issue,
all editable in place: title, status (dropdown), priority
(P0..P4 dropdown), type (bug / feature / task / epic / chore /
decision), assignee, labels (comma separated), description
(Markdown textarea), dependencies, comments, plus five action
buttons at the bottom (Reopen or Close depending on current
state, Claim, Delete, Cancel, Save).

```
┌────────────────────────────────────────────────────────────────┐
│                                                                │
│                                                                │
│                                                                │
│                                                                │
│   📷  Detail modal open on a real bead. Every field            │
│       populated. Dep editor visible with a couple of           │
│       existing chips. Comment thread below with at least       │
│       one rendered comment. Action buttons row at bottom.      │
│                                                                │
│                                                                │
│                                                                │
│                                                                │
└────────────────────────────────────────────────────────────────┘
```

**Save** is diff-aware. It computes the difference between the
form values and the original loaded values, and only sends what
changed. If you only touched the priority, only `--priority N`
goes in the `bd update` call. If you cleared an assignee, the
call uses `--unassign` rather than `--assignee ""` (which `bd`
would treat as "no change"). If nothing changed, Save says "no
changes" and doesn't fire any call.

**Close** does what you'd expect, and also checks for the
classic "blocked by open issues" error case: if `bd` refuses to
close because there are open blockers, the UI surfaces a
confirm dialog listing the blocker ids and offers a "force
close" path that retries with `--force`.

**Reopen** is what the Close button becomes when the issue is
already closed. Single click.

**Claim** maps to `bd update --claim`, which is the one
genuinely atomic primitive in Beads: it sets `assignee` to the
caller and `status` to `in_progress` in one transaction, and
refuses (with `BdErrorKindAlreadyClaimed`) if someone else
already claimed it. This is the right primitive for two agents
fighting over the same issue.

**Delete** is destructive and it knows it. The confirm dialog
lists every issue that currently depends on the one you're
about to delete (capped at the first eight, with a "and more"
suffix if there are more). The deletion runs `bd delete --force`,
and `bd` cleans up the dangling dependency rows server-side; the
dependent issues stay, they just lose their reference to the
deleted one.

### The dependency editor

Halfway down the modal is the Dependencies section. Two rows:
"Blocked by" (this issue depends on...) and "Blocks" (...these
issues depend on this one). Each row shows existing dependencies
as chips with an `×` button for removal and a small tag showing
the dependency type if it isn't the default `blocks`.

Below each existing chip list is an add-row: a chip input and a
type dropdown. Type a bead id (autocomplete suggests known ids
as you type), pick a type if you don't want the default, hit
Enter or comma or Tab to add. The bridge call to `bd dep add`
fires immediately; the chip appears as soon as `bd` confirms.

Removing a chip works the same way: click the `×`, the bridge
fires `bd dep remove`, the chip disappears.

There's no separate Save for dependencies. Each edit is an
independent commit at the `bd` level, so they're transactional
on the database side without needing to be batched in the UI.

```
┌────────────────────────────────────────────────────────────────┐
│                                                                │
│                                                                │
│   📷  Detail modal zoomed to the Dependencies section. Two     │
│       existing "Blocked by" chips (one labeled with a          │
│       non-default type like "waits-for"), one "Blocks" chip,   │
│       and an add-row underneath with the type dropdown         │
│       visible and an autocomplete popover showing suggested    │
│       bead ids.                                                │
│                                                                │
│                                                                │
└────────────────────────────────────────────────────────────────┘
```

### The comments thread

Below the dependency editor is the Comments section. Existing
comments render as Markdown (via `marked` plus DOMPurify
sanitization, both vendored offline). Author and timestamp at
the top of each comment, the rendered body below. Code fences
get monospace styling; links are clickable; bold and italic
work; you can paste a small image data-URL and it renders.

Add a comment via the textarea below the thread. Cmd-Enter
posts. Empty body is rejected client side (the bridge handler
also rejects, defensively). On post, the thread reloads from
`bd show` and the new comment appears at the bottom.

A note on field names: Beads's comment schema isn't perfectly
stable across versions. NppBeads reads the body, author, and
timestamp using a fallback chain (`body || text || content`,
`author || created_by || user || actor`, `created_at ||
timestamp`) so it tolerates whatever the current `bd` version
returns.

```
┌────────────────────────────────────────────────────────────────┐
│                                                                │
│                                                                │
│   📷  Detail modal's Comments section with three or four       │
│       comments rendered: mixed human and agent authorship,     │
│       a fenced code block in one of them (monospaced), a       │
│       bulleted list in another, timestamps visible. The        │
│       compose textarea below with a half-typed reply.          │
│                                                                │
│                                                                │
└────────────────────────────────────────────────────────────────┘
```

## Editor integration: the killer feature

This is the bit that made the plugin worth writing.

NppBeads scans every text buffer you have open, looking for
bead-id tokens that match `bd-[a-z0-9]+(\.\d+)*`. The match
matches `bd-a3f8`, `bd-deadbeef`, `bd-a3f8.1.2` (the dotted
hierarchical form Beads uses for parent-child relations), and
similar. Real ids: yes. False positives in normal English: no
(English doesn't tend to have words like `bd-a3f8`).

```
┌────────────────────────────────────────────────────────────────┐
│                                                                │
│                                                                │
│   📷  An NPP editor pane showing a TODO comment with two       │
│       blue-highlighted bead-ids inline (e.g. bd-a3f8 and       │
│       bd-deadbeef). Caret on one of them.                      │
│                                                                │
│                                                                │
└────────────────────────────────────────────────────────────────┘
```

Matched ids get colored blue inline using a Scintilla
indicator. The indicator updates as you type, scroll, or switch
buffers, debounced at 150 ms so it doesn't fight the editor's
own rendering.

Three commands hang off this:

* **Plugins → NppBeads → Jump to bead under caret**
  (Cmd-Option-Shift-J). Whatever bead-id the caret is sitting
  on, the panel pops, switches to the Board view, and opens the
  detail modal for that bead. If your caret is between
  characters of a known bead, the inclusive match still picks
  it up. If your caret isn't on a bead, you get a beep.

* **Plugins → NppBeads → Copy bead id under caret**. Writes the
  id to the system clipboard. No keyboard shortcut by default
  because Cmd-C is sacred.

* **Plugins → NppBeads → Create issue from selection**
  (Cmd-Option-Shift-N). Whatever you have selected in the
  editor (capped at four kilobytes, whitespace collapsed,
  newlines flattened) gets dropped into the title field of a
  freshly opened "+ New issue" modal. Your last-known panel
  context is preserved, so the new issue lands in the same
  project.

The day-to-day pattern that made this worth building: writing
code, encountering a comment like `// TODO(bd-a3f8): handle the
edge case where the cache is cold`, ⌘⌥⇧J, glance at the issue's
description and acceptance criteria, dismiss the modal, keep
typing. Whole interaction takes three seconds, costs zero
context.

```
┌────────────────────────────────────────────────────────────────┐
│                                                                │
│                                                                │
│   📷  Split screenshot. Left half: the editor with a TODO      │
│       comment visible, caret on a blue-highlighted bead-id,    │
│       ⌘⌥⇧J about to be pressed. Right half (same frame,       │
│       just moments later): NppBeads panel popped open to the   │
│       Board view, detail modal floating over it showing the    │
│       referenced bead's title, description, and status.        │
│                                                                │
│                                                                │
└────────────────────────────────────────────────────────────────┘
```

There are a couple of things this doesn't do yet that are on
the wishlist. Hovering a colored bead-id with the mouse should
pop a small floating preview card; that requires a host-level
change in Notepad++ to forward Scintilla's hover notifications
to plugins. Clicking a colored bead-id directly should also
jump to its detail modal; same problem (host needs to forward
the click notification). Both are documented in
`docs/HOST_CHANGES_BACKLOG.md` and waiting for a green light to
land in the host repo.

## Live updates

NppBeads keeps itself current with two independent mechanisms.

The first is a file watcher on `.beads/issues.jsonl`. Beads
maintains this file as a denormalized JSONL export of the issue
table, updated on every commit. Any time the file changes
on disk (because of a write you did in NppBeads, a teammate's
push, or an agent running `bd close` from a script), the
watcher fires within 750 ms and the panel re-reads the data.

The second is a two second poll of `bd list --all --json`. This
catches changes that don't go through the JSONL file (for
example, certain server-only Dolt operations). The poll
hash-diffs the result against the previous tick and only fires
a refresh if something actually changed, so it's not pushing
empty re-renders all day.

Both mechanisms are coordinated. They both call the same
internal "refresh" path, which is idempotent and reconciles
optimistic UI state with confirmed state.

The poll pauses automatically when Notepad++ isn't the focused
application. If you alt-tab to a browser, the panel stops
polling. When you come back, the poll resumes and picks up any
changes that landed in the meantime within one cycle. This
matters mostly for the case where an agent is running in a
terminal you're not watching: you don't want NPP burning bd
processes while you're working in another app.

There's also a "drag-guard" in the Board view. If a refresh
fires while you're mid-drag of a card, the render is deferred
until your drag ends. Without this, the dragged card's DOM node
would get replaced by the refresh and the drag would die in
your hand. Eight second watchdog releases the guard if the
drag-end event somehow doesn't fire (drop outside the window,
modifier-key issues, etc.).

## Living in the Graph view

Of the six views, Graph is the one I want to dwell on, because
it's where the plugin's structural-thinking superpowers live.

```
┌────────────────────────────────────────────────────────────────┐
│                                                                │
│                                                                │
│                                                                │
│   📷  Graph view with Heatmap toggled ON, metric=PageRank.     │
│       A few large red nodes visible at the structural          │
│       center of the layout, smaller green nodes at the         │
│       periphery, edges connecting them with cyan particles     │
│       flowing along.                                           │
│                                                                │
│                                                                │
│                                                                │
└────────────────────────────────────────────────────────────────┘
```

The graph is rendered using `force-graph` (a vendored npm
package wrapping D3 forces) inside the WebKit canvas. Nodes are
issues. Edges are dependencies, drawn as curved lines between
related issues. Two cyan particles flow along each edge; this is
a visual cue, not a metric, but a node with a steady inflow of
particles from many sides is one a lot of work funnels through.

Which way the arrowhead points and which direction the particles
travel depends on the **Arrows** dropdown in the Display panel
(covered a few paragraphs down). The default, Execution Flow,
points arrows from prerequisite to dependent — the temporal
reading: "first this, then that." The alternate, Dependency
Flow, points the other way — the build-system reading: "this
depends on that." Both describe the same graph; they just
verbalize it differently.

```
┌────────────────────────────────────────────────────────────────┐
│                                                                │
│                                                                │
│   📷  Side-by-side comparison of the same three-node chain     │
│       (GPU → train prod → train ASCII) rendered first in       │
│       Execution Flow mode (arrows point in time order) and     │
│       then in Dependency Flow mode (arrows reversed). The      │
│       Display panel's Arrows dropdown visible in the corner    │
│       of each.                                                 │
│                                                                │
│                                                                │
└────────────────────────────────────────────────────────────────┘
```

A small Display panel in the upper right of the Graph view
controls five things:

* **Heatmap toggle**. When on, every node is colored by its
  current value of the selected metric (next bullet),
  green to red, low to high.
* **Metric dropdown**. Five options: PageRank (recursive
  importance based on the graph's link structure), Betweenness
  Centrality (fraction of shortest paths between all node pairs
  that pass through this one), Critical Path (depth along the
  longest dependency chain), In-Degree (count of issues this
  one is blocked by). Each picks out a different kind of
  importance, so cycling through them gives different
  perspectives on the same project.
* **Arrows dropdown**. Two options: **Execution Flow** (default
  — arrow points from prerequisite to dependent, matching how
  you'd describe work temporally: "do A, then B, then C") and
  **Dependency Flow** (arrow points from dependent to
  prerequisite, matching how build systems talk: "this depends
  on that"). Flipping the mode reverses both the arrowheads
  and the direction the cyan particles travel in the same
  motion, so the two stay coherent. Your choice persists
  per-user across reloads. Underneath, the stored data model
  doesn't change — every metric computed from the dependency
  graph (PageRank, critical path, blocker counts) stays
  semantically identical regardless of which way the arrows
  point.
* **View dropdown**. Seven options: Default View (force-directed
  with a soft reset back to the boot state, useful when you've
  dragged things around and want to re-equilibrate), Force View
  (same physics-based layout but no zoom-to-fit), Compact View
  (a hierarchical DAG layout, good for narrow projects with
  deep chains), Spread View (more spacing, good for
  screenshots), Grid View, Radial View, and Cluster View
  (groups nodes by status). Switch between them while watching;
  the simulation re-runs each time.
* **Fire marks**. Optional 🔥 glyphs over high-priority nodes
  (P0 gets two flames, P1 gets one). Useful when you're
  scanning for hot items and don't want to enable the heatmap.
* **Particles**. Toggle the animated dots flowing along edges.
  Slight CPU cost, no effect on the data. Particles ride the
  same source-to-target axis as the arrowheads, so flipping
  the Arrows dropdown also reverses their flow direction.

The two metrics I find myself using most:

**PageRank** colors the structurally load-bearing issues red.
These are the ones the project funnels through (the database
schema migration; the API contract change; the build system
overhaul). When you're triaging "what's the highest-leverage
thing I could get done this week," PageRank's red set is the
short list.

**Betweenness centrality** colors the bridge nodes red. A
high-betweenness issue connects otherwise-independent regions
of the graph; resolving it unlocks parallel work in
streams that would otherwise stay parallel-but-stuck. Different
from PageRank: PageRank values depth, betweenness values
bridging.

The graph is also where the plugin's theme-awareness shows up
clearly. Switch the panel to light mode (theme button in the
toolbar) and the canvas redraws with a white background and a
darkened version of every status / priority / accent color, so
contrast remains readable. The same graph, dark or light,
within a couple of frames.

A specific limitation worth knowing about: arrowheads on
dependency edges align with the curved Bézier path (recently
fixed; previous versions had arrows misaligned with the curve)
and are visible inside dense clusters (also recent fix; old
versions dropped them when nodes overlapped). If you see
arrows that look wrong, you might be running an old version,
not the current one.

## Settings worth knowing

Three knobs.

**Theme.** A small icon next to the search field cycles through
Auto, Light, and Dark. Auto follows the macOS system appearance
(handy if you have a Shortcuts automation that flips system
theme at sunset). The selection persists in NSUserDefaults under
`NppBeadsThemePref`. The Graph view's force-graph canvas
listens for theme changes and repaints immediately; everything
else uses Tailwind's `dark:` class system and switches on the
class flip.

**Zoom.** Cmd-Plus, Cmd-Minus, and Cmd-Zero adjust the
WebView's `pageZoom` property. The default is 0.80 (everything
about twenty percent smaller than the upstream Tailwind sizing,
so the Dashboard and Insights views fit a typical docked-panel
width without you having to drag the divider out to seven
hundred pixels). Each Cmd-Plus or Cmd-Minus is a ten percent
step, clamped to the range 0.50 to 2.00 and snapped to a 0.05
grid so repeated presses don't drift via floating-point
accumulation. Cmd-Zero resets to default. The setting persists
under `NppBeadsPanelZoom`.

The keystrokes only fire when the WebView has focus. If your
focus is in the NPP editor, Cmd-Plus and Cmd-Minus fall through
to NPP's own editor zoom controls, which is the right behavior;
the shortcut is contextual based on which surface you're
interacting with.

**Auto-push.** This is the one with subtlety. By default, every
`bd` call NppBeads makes includes the `--sandbox` flag, which
disables Beads's automatic dolt-push step (the part where it
pushes the underlying Dolt commit to a configured git remote).
With `--sandbox` on, writes return in a fraction of a second.
Without it, every write attempts the push, and if your project
has a remote configured but no working non-interactive git auth
(no SSH agent, no credential helper), every write hangs about
twenty-three seconds while Git tries to prompt for credentials
that the subprocess can't accept.

So the default is sandbox-on and writes are fast and local. The
overflow menu (`⋯`) has an item called "Enable bd auto-push for
this project" which flips that flag for the currently-bound
project. Use it only if you have working non-interactive git
auth on the project's `sync.remote`. The opt-in is persisted
per-project in NSUserDefaults under
`NppBeadsAutoPushProjects`. The first time you flip it on for a
project, an alert explains the trade-off explicitly so you know
what you're getting into.

## Working alongside AI agents in practice

A few patterns that have worked well for me when running agents
that use the same Beads project I'm browsing through NppBeads.

**Let the agent claim before working.** Have the agent run `bd
update <id> --claim --json` as the first step on any issue.
That sets the assignee to the agent's actor name (configured
via the `BEADS_ACTOR` env var or `--actor` flag) and status to
`in_progress` atomically. If you happen to grab the same issue
from NppBeads at the same moment, one of the two will lose the
race cleanly, and you'll see the conflict instead of fighting
over a half-edited card.

**Use `bd ready --json` for what's-next.** This filter respects
all ten dependency types and only returns genuinely unblocked
work. An agent that just picks the first item from
`bd list --all --json` will pick blocked work and waste cycles;
`bd ready` gives you the actually-ready set. Same logic applies
when you're triaging from NppBeads: the Activity view's sort
shows recent work, but the Insights view's "Top Picks" is the
ready-set ranked.

**Have the agent post comments at meaningful boundaries.**
"Started", "ran tests, here are the failures", "fixed,
committed in abc123", "discovered this also breaks bd-c2,
filing follow-up." These will show up in the comments thread of
each issue, rendered as Markdown with timestamps, attributed to
the agent's actor. Reviewing the agent's work after the fact
becomes "scroll through Activity" instead of "read a slack log
in a tab."

**Use `discovered-from` dependencies for follow-ups.** When the
agent finds a bug while working on an unrelated issue, have it
file a new issue with a `discovered-from` dependency back to
the original. NppBeads renders the relationship in both
issues' Dependencies sections with the right type tag, so when
you're reviewing later you can trace why each issue was filed.

**Run the agent's bd calls in a directory inside the repo.** Bd
finds the project the same way NppBeads does (walks up looking
for `.beads/`), so an agent script doesn't need to be told
where the project is, only to be invoked from somewhere inside
it. If you're scripting multiple agents on multiple projects,
use a per-project working directory and a per-agent
`BEADS_ACTOR` env var.

## Tips and tricks

A grab bag of small things that took me a while to figure out.

**Cmd-Enter in any textarea posts.** Both the create-issue
description and the comment-add textarea support Cmd-Enter as
a submit shortcut. Saves the trip to the Submit button.

**The Activity badge resets only when you visit Activity.**
Visiting any other view doesn't acknowledge the count. If
you're seeing "● 23 new" and don't want to read all twenty
three updates, open Activity and immediately switch to a
different view; the badge clears.

**Project switcher remembers paths, not files.** If you bind
to `~/projects/foo` and later move it to `~/work/foo`, the
recent entry will be filtered out of the dropdown silently
(because the `.beads/` at the old path doesn't exist anymore).
You'll have to re-discover it via "Open .beads folder…" or by
opening a file from the new location.

**The dep editor accepts comma and Tab too.** If Enter is
inconvenient (because you have something else bound to it),
pressing comma or Tab while typing in a chip-input also
commits the chip.

**The diagnostics action copies the actual full state.**
`⋯ → Copy diagnostics to clipboard` writes a multi-section
text dump to the clipboard: paths, version info, JSONL
length, web-bridge state, recent console logs. Paste into
any bug report you file. The alert that appears just confirms
the copy size; it doesn't show the contents (the contents are
on the clipboard, ready to paste).

## Limitations to be honest about

A few things NppBeads doesn't do, on purpose or out of
necessity:

**No cross-repo view.** Each `.beads/` is independent. If you
work across two repos with two trackers, you switch projects
in the dropdown to switch trackers. There's no aggregated
"all my open work across all projects" view. Beads supports
cross-repo dependencies via `external:other-project:bd-X`
references, but NppBeads doesn't render them as live links;
they appear as plain text in the dependency list.

**No hover preview on bead-ids.** The blue colored ids in
your editor are visible but inert until you put your caret on
one and use ⌘⌥⇧J. The hover preview is documented in the
backlog; it requires Notepad++ to forward Scintilla's
DwellStart notification to plugins, which it doesn't do today.

**No click-to-jump on bead-ids.** Same root cause; needs
Scintilla's HotspotClick forwarded.

**Per-issue comments don't auto-refresh.** The Board and
Activity views auto-refresh on `bd` activity. The detail
modal's comments thread does not. If a teammate posts a
comment while your modal is open, you won't see it until you
close and reopen the modal. This is a deliberate scope
decision (the alternative is more bridge plumbing for a case
that doesn't come up often) but it's a real limitation.

**Graph mid-session theme switch only takes effect on
re-render of dynamic content.** The canvas itself flips
correctly on theme change. A few inline-styled overlay
elements that were built with theme colors at construction
time may need a view switch to refresh. In practice this is
rarely visible.

**The macros menu integration cuts off at the host's plugin
namespace.** Our menu items live under `Plugins → NppBeads →
…` rather than at a top level `Beads` menu. That's a
discoverability cost, mitigated by keyboard shortcuts.

## Where it goes from here

Two more phases of work before NppBeads ships v1.0.0:

* **Phase 7 polish.** Saved filter presets on the Board and
  Issues views, in-panel keyboard shortcuts (N/E/C/G/`/`), a
  light-mode pass on the Rich viewer, a `bd dolt status` chip
  in the status bar, structured "Copy diagnostics" bundle
  that produces a zip instead of a text blob. Two days of
  work.

* **Phase 8 distribution.** Apple notarization on the dylib,
  README rewrite, submission to NPP's plugin index for
  in-product discoverability, listing in the upstream Beads
  community-tools documentation, GitHub release with the
  signed zip. Two days of work.

If you've gotten this far and decide to try it, the repo is at
[notepad-plus-plus-mac/NppBeads](https://github.com/notepad-plus-plus-mac/NppBeads).
The `docs/` folder has phase-by-phase test matrices that double
as feature documentation, plus a host-changes backlog and
status notes. Bugs and feature requests welcome on the issue
tracker (which, for what it's worth, is hosted on GitHub
Issues; we eat our own dogfood up to the point where we'd need
to host the Beads CLI from a web service to do otherwise).
