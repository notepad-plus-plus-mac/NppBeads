// Board view — status-based kanban. Columns: Open, In Progress,
// Blocked, Closed. DnD between columns. Closed is collapsed by default
// (matches vscode-beads UX). Optimistic status overrides for instant
// feedback; real persistence wires in Phase 3.
//
// Ported in spirit from jdillon/vscode-beads/src/webview/views/
// KanbanBoard.tsx (Apache-2.0) — de-Reacted to vanilla JS.
// ─────────────────────────────────────────────────────────────────────

(function () {
  'use strict';

  const App = window.__nppApp;
  if (!App) { console.error('[Board] app.js not loaded'); return; }

  const COLUMNS = [
    { status: 'open',        label: 'Open'         },
    { status: 'in_progress', label: 'In Progress'  },
    { status: 'blocked',     label: 'Blocked'      },
    { status: 'closed',      label: 'Closed'       },
  ];

  // Optimistic status overrides: instant visual response to a drop,
  // cleared once the real data catches up (native re-push). A Map here
  // vs object so keys can be arbitrary strings with no prototype
  // pollution.
  const optimistic = new Map();

  // ── Status mode ─────────────────────────────────────────────────────
  // 'raw'       — group by the stored `status` field (what bd wrote).
  // 'effective' — promote open/in_progress issues that have at least one
  //               non-closed `blocks` dependency into the Blocked column
  //               (matches what `bd ready` / `bd status` consider blocked).
  // The raw `status` field is never rewritten by bd just because a dep
  // opened — the graph-based blocked state is computed on the fly. This
  // toggle surfaces that distinction without changing any data.
  const MODE_KEY = 'nppbeads.board.statusMode';
  function loadMode() {
    try {
      const v = localStorage.getItem(MODE_KEY);
      return v === 'effective' ? 'effective' : 'raw';
    } catch { return 'raw'; }
  }
  function saveMode(m) {
    try { localStorage.setItem(MODE_KEY, m); } catch {}
  }
  let statusMode = loadMode();

  function hasOpenBlocker(bead) {
    if (!bead || !bead.deps || !bead.deps.length) return false;
    for (const d of bead.deps) {
      const kind = d.dependency_type || d.type || 'blocks';
      if (kind !== 'blocks') continue;
      // bd embeds the target's current status on each dep entry, so we
      // can decide without a cross-lookup. Treat an absent status as
      // 'open' — a conservative default so an export without statuses
      // still surfaces blockage rather than silently hiding it.
      const s = d.status || 'open';
      if (s !== 'closed') return true;
    }
    return false;
  }

  // Persisted column collapse state (per-browser-tab; survives reload).
  const COLLAPSED_KEY = 'nppbeads.board.collapsed';
  function loadCollapsed() {
    try {
      const raw = localStorage.getItem(COLLAPSED_KEY);
      if (!raw) return new Set(['closed']);  // sensible default
      const arr = JSON.parse(raw);
      return new Set(Array.isArray(arr) ? arr : ['closed']);
    } catch { return new Set(['closed']); }
  }
  function saveCollapsed(set) {
    try { localStorage.setItem(COLLAPSED_KEY, JSON.stringify([...set])); }
    catch {}
  }
  const collapsed = loadCollapsed();

  const boardEl    = document.getElementById('board');
  const cardTpl    = document.getElementById('card-tpl');
  const colTpl     = document.getElementById('col-tpl');

  function effectiveStatus(b) {
    const ov = optimistic.get(b.id);
    const base = ov || b.status;
    if (statusMode !== 'effective') return base;
    if ((base === 'open' || base === 'in_progress') && hasOpenBlocker(b)) {
      return 'blocked';
    }
    return base;
  }

  function groupByStatus(beads) {
    const out = { open: [], in_progress: [], blocked: [], closed: [] };
    for (const b of beads) {
      if (!App.matchesQuery(b, App.filter.query)) continue;
      const s = effectiveStatus(b);
      if (out[s]) out[s].push(b);
    }
    // Within each column, sort: priority asc (P0 first), then updated desc.
    for (const s of Object.keys(out)) {
      out[s].sort((a, b) => {
        const pa = a.priority ?? 99, pb = b.priority ?? 99;
        if (pa !== pb) return pa - pb;
        return String(b.updatedAt || '').localeCompare(String(a.updatedAt || ''));
      });
    }
    return out;
  }

  // ── DnD handlers ────────────────────────────────────────────────────
  // Drag-guard: when a card is being dragged, we must NOT re-render
  // the board out from under the user's cursor — the DOM node being
  // dragged would get replaced and the drag would die. The live-sync
  // poll (Phase 4) and the watcher fire refreshes independently of DnD,
  // so we defer them until dragend. See App.onRefresh below.
  let isDraggingCard = false;
  let pendingRefresh = false;
  let dragWatchdog   = null;  // safety: fire a reset if dragend is missed

  function _beginDragGuard() {
    isDraggingCard = true;
    if (dragWatchdog) clearTimeout(dragWatchdog);
    // 8s is plenty — DnD on macOS rarely exceeds 2-3s. If we hit the
    // watchdog, the user probably dropped outside the window and the
    // browser swallowed the dragend. We release the guard so the next
    // refresh isn't stuck forever.
    dragWatchdog = setTimeout(() => {
      dragWatchdog   = null;
      isDraggingCard = false;
      _flushDeferredRefresh();
    }, 8000);
  }
  function _endDragGuard() {
    isDraggingCard = false;
    if (dragWatchdog) { clearTimeout(dragWatchdog); dragWatchdog = null; }
    _flushDeferredRefresh();
  }
  function _flushDeferredRefresh() {
    if (!pendingRefresh) return;
    pendingRefresh = false;
    _runRefresh();
  }

  function onDragStart(e) {
    const id = e.currentTarget.dataset.beadId;
    if (!id) return;
    e.dataTransfer.setData('text/plain', id);
    e.dataTransfer.effectAllowed = 'move';
    e.currentTarget.classList.add('card-dragging');
    _beginDragGuard();
  }
  function onDragEnd(e) {
    e.currentTarget.classList.remove('card-dragging');
    _endDragGuard();
  }
  function onDragOver(e) {
    e.preventDefault();
    e.dataTransfer.dropEffect = 'move';
    const col = e.currentTarget;
    col.classList.add('col-drag-over');
  }
  function onDragLeave(e) {
    e.currentTarget.classList.remove('col-drag-over');
  }
  function onDrop(e) {
    e.preventDefault();
    const col = e.currentTarget;
    col.classList.remove('col-drag-over');
    const newStatus = col.dataset.status;
    const beadId = e.dataTransfer.getData('text/plain');
    if (!beadId || !newStatus) return;

    const bead = App.beads.find(b => b.id === beadId);
    if (!bead) return;
    const oldStatus = effectiveStatus(bead);
    if (oldStatus === newStatus) return;

    // Optimistic move — render instantly; then ask native to persist.
    optimistic.set(beadId, newStatus);
    render();

    // No bridge / no bd backend → stay optimistic + show a hint.
    if (!window.__nppBridge) {
      showToast('Moved ' + bead.id + ' (ephemeral — no bridge)');
      return;
    }
    window.__nppBridge.call('updateBead', {
      id: beadId,
      status: newStatus,
    }).then((resp) => {
      if (resp.ok) {
        // Real data will arrive via onRefresh broadcast from native;
        // optimistic.delete in onRefresh handles cleanup.
        showToast(bead.id + ' → ' + App.statusColor(newStatus).label);
      } else {
        // Roll back the optimistic move.
        optimistic.delete(beadId);
        render();
        const msg = resp.error || 'update failed';
        if (resp.errorKind === 1 /* ReadOnly */) {
          showToast('Install `bd` to enable editing');
        } else {
          showToast(bead.id + ' · ' + msg);
        }
      }
    }).catch((err) => {
      optimistic.delete(beadId);
      render();
      showToast(bead.id + ' · ' + (err.message || err));
    });
  }

  // ── Toggle column collapse ──────────────────────────────────────────
  function onToggleCol(e) {
    const col = e.currentTarget.closest('.col');
    const s = col.dataset.status;
    if (collapsed.has(s)) collapsed.delete(s); else collapsed.add(s);
    saveCollapsed(collapsed);
    render();
  }

  // ── Card click: show in-place detail modal ─────────────────────────
  // No navigation — all the bead's info is shown in an overlay directly
  // on the Board. Click outside or press Esc to close. Dependency chips
  // are clickable and open the linked bead in the same modal.
  function onCardClick(e) {
    if (e.target.closest('.card-id')) return;  // let the <a> handle it
    const id = e.currentTarget.dataset.beadId;
    if (!id) return;
    openBeadModal(id);
  }

  // Find the original JSONL record for a bead id (has the full
  // description, dependencies, timestamps) — App.beads only has the
  // normalized subset, but the raw deps are on `.deps`.
  function findBead(id) {
    return App.beads.find(b => b.id === id) || null;
  }

  function el(tag, attrs, ...children) {
    const n = document.createElement(tag);
    if (attrs) for (const k in attrs) {
      if (k === 'class') n.className = attrs[k];
      else if (k === 'style') n.setAttribute('style', attrs[k]);
      else if (k.startsWith('on') && typeof attrs[k] === 'function')
        n.addEventListener(k.slice(2).toLowerCase(), attrs[k]);
      else if (attrs[k] != null) n.setAttribute(k, attrs[k]);
    }
    for (const c of children) {
      if (c == null || c === false) continue;
      n.appendChild(c instanceof Node ? c : document.createTextNode(String(c)));
    }
    return n;
  }

  function fmtTime(iso) {
    if (!iso) return null;
    try {
      const d = new Date(iso);
      if (isNaN(d.getTime())) return iso;
      return d.toLocaleString(undefined, {
        year: 'numeric', month: 'short', day: 'numeric',
        hour: '2-digit', minute: '2-digit',
      });
    } catch { return iso; }
  }

  function buildPills(b) {
    const row = el('div', { class: 'modal-pills' });
    const s = App.statusColor(b.status);
    row.appendChild(el('span', {
      class: 'pill',
      style: `background:${s.bg};color:${s.fg}`,
    }, s.label));
    const p = App.priorityBadge(b.priority);
    if (p) row.appendChild(el('span', {
      class: 'pill', style: `background:${p.color};color:#fff`,
    }, p.label));
    if (b.type) row.appendChild(el('span', {
      class: 'pill pill-type',
    }, App.typeIcon(b.type) + ' ' + b.type));
    if (b.assignee) row.appendChild(el('span', {
      class: 'pill pill-assignee',
    }, '@' + b.assignee));
    return row;
  }

  function buildLabels(labels) {
    if (!labels || !labels.length) return null;
    const row = el('div', { class: 'modal-labels' });
    for (const l of labels) {
      row.appendChild(el('span', {
        class: 'pill pill-label',
        style: `border-color:${App.labelColor(l)};color:${App.labelColor(l)}`,
      }, l));
    }
    return row;
  }

  function buildDeps(b) {
    const deps = b.deps || [];
    if (!deps.length) return null;
    // Two groups: this bead depends on (blocked_by), this bead blocks (blocks).
    const blockedBy = [], blocks = [];
    for (const d of deps) {
      const row = { id: d.depends_on_id || d.issue_id, type: d.type || 'blocks' };
      if (d.issue_id === b.id) blockedBy.push(row);
      else if (d.depends_on_id === b.id) blocks.push(row);
    }
    const wrap = el('div', { class: 'modal-deps' });
    if (blockedBy.length) {
      wrap.appendChild(el('h4', null, 'Blocked by'));
      const list = el('div', { class: 'dep-list' });
      for (const x of blockedBy) list.appendChild(depChip(x));
      wrap.appendChild(list);
    }
    if (blocks.length) {
      wrap.appendChild(el('h4', null, 'Blocks'));
      const list = el('div', { class: 'dep-list' });
      for (const x of blocks) list.appendChild(depChip(x));
      wrap.appendChild(list);
    }
    return wrap;
  }

  function depChip(d) {
    const target = findBead(d.id);
    const chip = el('a', {
      class: 'dep-chip',
      href: '#',
      title: target ? target.title : d.id,
      onclick: (e) => { e.preventDefault(); openBeadModal(d.id); },
    });
    chip.appendChild(el('span', { class: 'dep-id' }, d.id));
    if (target) {
      const s = App.statusColor(target.status);
      chip.appendChild(el('span', {
        class: 'dep-status',
        style: `background:${s.bg};color:${s.fg}`,
      }, s.label));
    }
    return chip;
  }

  function openBeadModal(id) {
    const b = findBead(id);
    closeBeadModal();

    const overlay = el('div', {
      class: 'modal-overlay',
      onclick: (e) => { if (e.target === overlay) closeBeadModal(); },
    });
    overlay.id = 'bead-modal';

    if (!b) {
      overlay.appendChild(el('div', { class: 'modal-card' },
        el('div', { class: 'modal-hdr' },
          el('span', { class: 'modal-id' }, id),
          el('button', {
            class: 'modal-close',
            'aria-label': 'Close',
            onclick: closeBeadModal,
          }, '×'),
        ),
        el('div', { class: 'modal-body' },
          el('p', { class: 'modal-missing' }, 'Issue not found in current project data.'),
        ),
      ));
      document.body.appendChild(overlay);
      return;
    }

    const card = el('div', { class: 'modal-card modal-edit' });

    // Header: type icon + id + close button
    const hdr = el('div', { class: 'modal-hdr' });
    hdr.appendChild(el('span', { class: 'modal-type' }, App.typeIcon(b.type)));
    hdr.appendChild(el('span', { class: 'modal-id' }, b.id));
    const closeBtn = el('button', {
      class: 'modal-close',
      'aria-label': 'Close',
      onclick: closeBeadModal,
    }, '×');
    hdr.appendChild(closeBtn);
    card.appendChild(hdr);

    // Editable body (no <form> — we post per-field on Save).
    const body = el('div', { class: 'modal-body' });

    // Title (editable)
    const titleInput = el('input', {
      type: 'text',
      class: 'edit-title',
      value: b.title || '',
      placeholder: 'Title',
    });
    body.appendChild(el('label', { class: 'field' },
      el('span', { class: 'field-label' }, 'Title'),
      titleInput));

    // Status / priority / type / assignee on one row
    const statusSel = makeSelect('status', [
      ['open',        'Open'],
      ['in_progress', 'In Progress'],
      ['blocked',     'Blocked'],
      ['deferred',    'Deferred'],
      ['closed',      'Closed'],
    ], b.status);
    const prioSel = makeSelect('priority', [
      ['0', 'P0 — critical'],
      ['1', 'P1 — high'],
      ['2', 'P2 — normal'],
      ['3', 'P3 — low'],
      ['4', 'P4 — trivial'],
    ], String(b.priority == null ? 2 : b.priority));
    const typeSel = makeSelect('issueType', [
      ['task', 'task'], ['bug', 'bug'], ['feature', 'feature'],
      ['epic', 'epic'], ['chore', 'chore'], ['decision', 'decision'],
    ], b.type || 'task');
    const assigneeInput = el('input', {
      type: 'text', class: 'edit-assignee',
      value: b.assignee || '', placeholder: '@user',
    });
    const metaRow = el('div', { class: 'field-row' });
    metaRow.appendChild(wrapField('Status',   statusSel));
    metaRow.appendChild(wrapField('Priority', prioSel));
    metaRow.appendChild(wrapField('Type',     typeSel));
    metaRow.appendChild(wrapField('Assignee', assigneeInput));
    body.appendChild(metaRow);

    // Labels (comma-separated)
    const labelsInput = el('input', {
      type: 'text',
      class: 'edit-labels',
      value: (b.labels || []).join(', '),
      placeholder: 'comma, separated, labels',
    });
    body.appendChild(wrapField('Labels', labelsInput));

    // Description (markdown textarea)
    const descInput = el('textarea', {
      class: 'edit-desc', rows: '8', placeholder: 'Markdown description…',
    });
    descInput.value = b.description || '';
    body.appendChild(wrapField('Description', descInput));

    // Dependencies — editable in Phase 3.5. We keep a persistent
    // container and re-render it after every dep op so the modal
    // reflects the new state immediately (the Board refresh also fires
    // via _broadcastDataChanged, but that updates App.beads; the open
    // modal doesn't re-open on its own).
    const depContainer = el('div', { class: 'modal-dep-editor' });
    body.appendChild(depContainer);
    renderDepEditor(depContainer, b.id);

    // Timestamps
    const ts = el('div', { class: 'modal-ts' });
    const pairs = [
      ['created',  fmtTime(b.createdAt)],
      ['updated',  fmtTime(b.updatedAt)],
      ['closed',   fmtTime(b.closedAt)],
    ];
    for (const [k, v] of pairs) if (v) {
      const row = el('div', { class: 'ts-row' });
      row.appendChild(el('span', { class: 'ts-k' }, k));
      row.appendChild(el('span', { class: 'ts-v' }, v));
      ts.appendChild(row);
    }
    body.appendChild(ts);

    // Action bar: status line + close/reopen/claim + delete + cancel/save.
    const actions = el('div', { class: 'modal-actions' });
    const statusLine = el('span', { class: 'form-status' });
    actions.appendChild(statusLine);

    const isClosed = b.status === 'closed';
    const toggleLabel = isClosed ? 'Reopen' : 'Close';
    const toggleBtn = el('button', {
      type: 'button', class: 'btn btn-secondary edit-toggle-close',
    }, toggleLabel);
    toggleBtn.addEventListener('click', () => {
      if (isClosed) doReopen(b, statusLine, toggleBtn);
      else          doClose(b,  statusLine, toggleBtn);
    });
    actions.appendChild(toggleBtn);

    const claimBtn = el('button', {
      type: 'button', class: 'btn btn-secondary edit-claim',
    }, 'Claim');
    claimBtn.addEventListener('click', () => doClaim(b, statusLine, claimBtn));
    actions.appendChild(claimBtn);

    // Phase 3.5 — destructive delete, kept last in the secondary row
    // and styled .btn-danger so it's obviously different from the
    // non-destructive ones. Confirm dialog lists any issues that
    // depend on this one (dep-sweep warning).
    const deleteBtn = el('button', {
      type: 'button', class: 'btn btn-danger edit-delete',
    }, 'Delete');
    deleteBtn.addEventListener('click', () => doDelete(b, statusLine, deleteBtn));
    actions.appendChild(deleteBtn);

    actions.appendChild(el('button', {
      type: 'button', class: 'btn btn-secondary',
      onclick: closeBeadModal,
    }, 'Cancel'));

    const saveBtn = el('button', {
      type: 'button', class: 'btn btn-primary edit-save',
    }, 'Save');
    saveBtn.addEventListener('click', async () => {
      const nextAssignee = assigneeInput.value.trim();
      const origAssignee = (b.assignee || '').trim();
      // Phase 3.5 — when the user clears a previously-set assignee, the
      // diffPatch would put assignee="" into the update, but bd treats
      // empty --assignee as "no change". We detect the clear here and
      // route it to the dedicated unassignBead bridge instead, BEFORE
      // the regular update so we don't send a stale assignee in the
      // same flight. bd serializes writes per-project (the plugin
      // awaits each call), so ordering is preserved.
      const clearingAssignee = origAssignee.length > 0 && nextAssignee.length === 0;
      const patch = diffBeadPatch(b, {
        title:       titleInput.value.trim(),
        status:      statusSel.value,
        priority:    parseInt(prioSel.value, 10),
        issueType:   typeSel.value,
        // Don't include the empty assignee in the patch — unassign
        // handles it separately below.
        assignee:    clearingAssignee ? origAssignee : nextAssignee,
        labels:      labelsInput.value.split(',').map(s => s.trim()).filter(Boolean),
        description: descInput.value,
      });
      if (!patch && !clearingAssignee) {
        statusLine.textContent = 'no changes';
        statusLine.classList.remove('is-error');
        return;
      }
      saveBtn.disabled = true;
      statusLine.classList.remove('is-error');
      statusLine.textContent = 'Saving…';
      if (!window.__nppBridge) {
        statusLine.textContent = 'native bridge unavailable';
        statusLine.classList.add('is-error');
        saveBtn.disabled = false;
        return;
      }
      try {
        if (clearingAssignee) {
          const r = await window.__nppBridge.call('unassignBead', { id: b.id });
          if (!r.ok) {
            statusLine.textContent = r.error || 'unassign failed';
            statusLine.classList.add('is-error');
            saveBtn.disabled = false;
            return;
          }
        }
        if (patch) {
          const resp = await window.__nppBridge.call('updateBead',
            Object.assign({ id: b.id }, patch));
          if (!resp.ok) {
            statusLine.textContent = resp.error || 'update failed';
            statusLine.classList.add('is-error');
            saveBtn.disabled = false;
            return;
          }
        }
        showToast(b.id + ' updated');
        closeBeadModal();
      } catch (err) {
        statusLine.textContent = (err && err.message) || String(err);
        statusLine.classList.add('is-error');
        saveBtn.disabled = false;
      }
    });
    actions.appendChild(saveBtn);

    body.appendChild(actions);
    card.appendChild(body);
    overlay.appendChild(card);
    document.body.appendChild(overlay);

    // Esc to close. Autofocus title — typical for a detail-edit flow.
    document.addEventListener('keydown', escCloser);
    setTimeout(() => { titleInput.focus(); titleInput.select(); }, 0);
  }

  // ── Helpers for the edit modal ──────────────────────────────────────
  function makeSelect(name, options, current) {
    const sel = el('select', { name });
    for (const [val, lbl] of options) {
      const opt = document.createElement('option');
      opt.value = val;
      opt.textContent = lbl;
      if (String(val) === String(current)) opt.selected = true;
      sel.appendChild(opt);
    }
    return sel;
  }
  function wrapField(label, input) {
    return el('label', { class: 'field' },
      el('span', { class: 'field-label' }, label),
      input);
  }

  // Build a minimal patch by comparing form values to the bead's current
  // state. Only keys that differ are sent — avoids pointless writes and
  // lets bd skip the "status unchanged" path, which triggers no git
  // activity on a save-without-changes.
  function diffBeadPatch(orig, next) {
    const out = {};
    if (next.title && next.title !== (orig.title || '')) out.title = next.title;
    if (next.status && next.status !== orig.status)      out.status = next.status;
    const origPrio = orig.priority == null ? null : Number(orig.priority);
    if (!Number.isNaN(next.priority) && next.priority !== origPrio) out.priority = next.priority;
    if (next.issueType && next.issueType !== (orig.type || 'task')) out.issueType = next.issueType;
    const origAssignee = orig.assignee || '';
    if (next.assignee !== origAssignee) out.assignee = next.assignee;
    const origLabels = (orig.labels || []).slice().sort().join(',');
    const nextLabels = (next.labels || []).slice().sort().join(',');
    if (origLabels !== nextLabels) {
      // bd has separate add / remove lists — compute delta.
      const origSet = new Set(orig.labels || []);
      const nextSet = new Set(next.labels || []);
      const add = [...nextSet].filter(l => !origSet.has(l));
      const rm  = [...origSet].filter(l => !nextSet.has(l));
      if (add.length) out.addLabels    = add;
      if (rm.length)  out.removeLabels = rm;
    }
    if ((next.description || '') !== (orig.description || '')) {
      out.description = next.description || '';
    }
    return Object.keys(out).length ? out : null;
  }

  function doClose(bead, statusLine, btn) {
    btn.disabled = true;
    statusLine.classList.remove('is-error');
    statusLine.textContent = 'Closing…';
    if (!window.__nppBridge) { statusLine.textContent = 'bridge unavailable'; return; }
    window.__nppBridge.call('closeBead', { id: bead.id })
      .then((resp) => {
        if (resp.ok) { showToast(bead.id + ' closed'); closeBeadModal(); }
        else if (resp.errorKind === 3 /* BlockedByDeps */ && resp.blockers) {
          if (confirm('This issue has open blockers: ' + resp.blockers.join(', ') +
                      '. Close anyway (force)?')) {
            statusLine.textContent = 'Closing (force)…';
            window.__nppBridge.call('closeBead', { id: bead.id, force: true })
              .then((r2) => {
                if (r2.ok) { showToast(bead.id + ' closed (force)'); closeBeadModal(); }
                else { statusLine.textContent = r2.error || 'force close failed';
                       statusLine.classList.add('is-error'); btn.disabled = false; }
              });
          } else { btn.disabled = false; statusLine.textContent = ''; }
        } else {
          statusLine.textContent = resp.error || 'close failed';
          statusLine.classList.add('is-error');
          btn.disabled = false;
        }
      });
  }
  function doReopen(bead, statusLine, btn) {
    btn.disabled = true;
    statusLine.classList.remove('is-error');
    statusLine.textContent = 'Reopening…';
    if (!window.__nppBridge) return;
    window.__nppBridge.call('reopenBead', { id: bead.id })
      .then((resp) => {
        if (resp.ok) { showToast(bead.id + ' reopened'); closeBeadModal(); }
        else {
          statusLine.textContent = resp.error || 'reopen failed';
          statusLine.classList.add('is-error');
          btn.disabled = false;
        }
      });
  }
  function doClaim(bead, statusLine, btn) {
    btn.disabled = true;
    statusLine.classList.remove('is-error');
    statusLine.textContent = 'Claiming…';
    if (!window.__nppBridge) return;
    window.__nppBridge.call('claimBead', { id: bead.id })
      .then((resp) => {
        if (resp.ok) { showToast(bead.id + ' claimed'); closeBeadModal(); }
        else {
          statusLine.textContent = resp.error || 'claim failed';
          statusLine.classList.add('is-error');
          btn.disabled = false;
        }
      });
  }

  // Phase 3.5 — permanent delete. Dep-sweep warning lists every issue
  // that currently depends on this one so the user sees which edges
  // will go dangling. bd handles the cleanup itself (deletes dangling
  // dependency rows when the target issue is deleted).
  function doDelete(bead, statusLine, btn) {
    if (!window.__nppBridge) {
      statusLine.textContent = 'bridge unavailable';
      statusLine.classList.add('is-error');
      return;
    }
    const dependents = App.beads
      .filter(x => (x.deps || []).some(d =>
        d.depends_on_id === bead.id && x.id !== bead.id))
      .map(x => x.id);
    let prompt = 'Permanently delete ' + bead.id + ' (' +
                 (bead.title || 'no title').slice(0, 60) + ')?';
    if (dependents.length) {
      prompt += '\n\n⚠ ' + dependents.length + ' issue' +
                (dependents.length === 1 ? '' : 's') +
                ' depend' + (dependents.length === 1 ? 's' : '') +
                ' on this: ' + dependents.slice(0, 8).join(', ') +
                (dependents.length > 8 ? ', …' : '') +
                '. Their dependency edges will be dropped.';
    }
    prompt += '\n\nThis cannot be undone.';
    if (!confirm(prompt)) return;
    btn.disabled = true;
    statusLine.classList.remove('is-error');
    statusLine.textContent = 'Deleting…';
    window.__nppBridge.call('deleteBead', { id: bead.id })
      .then((resp) => {
        if (resp.ok) {
          showToast(bead.id + ' deleted');
          // Optimistic board reconciliation — next _broadcastDataChanged
          // (triggered natively) will drop the card too, but clearing
          // optimistic state avoids a flash of the deleted card.
          optimistic.delete(bead.id);
          closeBeadModal();
        } else {
          statusLine.textContent = resp.error || 'delete failed';
          statusLine.classList.add('is-error');
          btn.disabled = false;
        }
      }).catch((err) => {
        statusLine.textContent = (err && err.message) || String(err);
        statusLine.classList.add('is-error');
        btn.disabled = false;
      });
  }

  // Populate the shared dep-suggest datalist from the current bead list.
  // Called by both the new-issue modal and the detail-modal dep editor
  // before they show chip-inputs that reference list="dep-suggest".
  function refreshDepSuggestions() {
    const dl = document.getElementById('dep-suggest');
    if (!dl) return;
    dl.innerHTML = '';
    const cap = Math.min(App.beads.length, 500);
    for (let i = 0; i < cap; i++) {
      const bd = App.beads[i];
      const opt = document.createElement('option');
      opt.value = bd.id;
      opt.label = bd.title || '';
      dl.appendChild(opt);
    }
  }

  // Phase 3.5 — render / re-render the editable dep section inside the
  // detail modal. Rebuilds in place after every dep op so the chips
  // reflect the live bead state without re-opening the modal.
  function renderDepEditor(container, beadId) {
    refreshDepSuggestions();
    container.innerHTML = '';
    const b = findBead(beadId);
    if (!b) {
      container.appendChild(el('p', { class: 'modal-missing' },
        'Bead not found in current data — refresh to reload.'));
      return;
    }

    container.appendChild(el('h4', { class: 'modal-dep-hdr' }, 'Dependencies'));
    const statusLine = el('span', { class: 'form-status dep-status-line' });
    container.appendChild(statusLine);

    // Partition existing deps by direction.
    const blockedBy = [];  // this issue depends on these
    const blocks    = [];  // these issues depend on this issue
    for (const d of (b.deps || [])) {
      const row = {
        id:    d.depends_on_id || d.issue_id,
        type:  d.type || 'blocks',
        dependent:  d.issue_id,
        dependency: d.depends_on_id,
      };
      if (d.issue_id === b.id)      blockedBy.push(row);
      else if (d.depends_on_id === b.id) blocks.push(row);
    }

    // Direction: "upstream" means new chips become our blockers
    //            (depAdd where dependent=us, dependency=chip)
    //            "downstream" means new chips become our dependents
    //            (depAdd where dependent=chip, dependency=us)
    buildDepGroup(container, {
      label:     'Blocked by',
      hint:      'upstream — this issue depends on:',
      existing:  blockedBy,
      beadId:    b.id,
      direction: 'upstream',
      statusLine,
      onChanged: () => renderDepEditor(container, beadId),
    });
    buildDepGroup(container, {
      label:     'Blocks',
      hint:      'downstream — these depend on this issue:',
      existing:  blocks,
      beadId:    b.id,
      direction: 'downstream',
      statusLine,
      onChanged: () => renderDepEditor(container, beadId),
    });
  }

  function buildDepGroup(container, opts) {
    const wrap = el('div', { class: 'dep-group' });
    const hdr  = el('div', { class: 'dep-group-hdr' });
    hdr.appendChild(el('span', { class: 'dep-group-label' }, opts.label));
    hdr.appendChild(el('span', { class: 'dep-group-hint hint' }, opts.hint));
    wrap.appendChild(hdr);

    const listRow = el('div', { class: 'dep-chip-list' });
    if (!opts.existing.length) {
      listRow.appendChild(el('span', { class: 'dep-empty' }, 'none'));
    } else {
      for (const x of opts.existing) listRow.appendChild(
        buildExistingDepChip(x, opts));
    }
    wrap.appendChild(listRow);

    // Add-row: input + type picker
    const addRow = el('div', { class: 'chip-input-row dep-add-row' });
    const inp = el('input', {
      type: 'text',
      placeholder: 'bd-… ↵',
      list: 'dep-suggest',
      autocomplete: 'off',
    });
    const typeSel = App.buildDepTypeSelect('blocks');
    addRow.appendChild(inp);
    addRow.appendChild(typeSel);
    wrap.appendChild(addRow);

    async function submitAdd() {
      const raw = inp.value.trim().replace(/,$/, '');
      if (!raw) return;
      if (raw === opts.beadId) {
        opts.statusLine.textContent = 'An issue cannot depend on itself.';
        opts.statusLine.classList.add('is-error');
        return;
      }
      const type = typeSel.value || 'blocks';
      // Direction maps to bd's (dependent, dependency) order.
      const dependent  = opts.direction === 'upstream' ? opts.beadId : raw;
      const dependency = opts.direction === 'upstream' ? raw         : opts.beadId;
      inp.disabled = true; typeSel.disabled = true;
      opts.statusLine.classList.remove('is-error');
      opts.statusLine.textContent = 'Adding dep…';
      try {
        const r = await window.__nppBridge.call('depAdd',
          { dependent, dependency, depType: type });
        if (r.ok) {
          inp.value = '';
          opts.statusLine.textContent = '';
          opts.onChanged();   // re-render container
        } else {
          opts.statusLine.textContent = r.error || 'dep add failed';
          opts.statusLine.classList.add('is-error');
        }
      } catch (e) {
        opts.statusLine.textContent = (e && e.message) || String(e);
        opts.statusLine.classList.add('is-error');
      } finally {
        inp.disabled = false; typeSel.disabled = false;
      }
    }

    inp.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' || e.key === ',' || e.key === 'Tab') {
        e.preventDefault(); submitAdd();
      }
    });
    // change fires when the datalist picks a value without Enter
    inp.addEventListener('change', submitAdd);

    container.appendChild(wrap);
  }

  function buildExistingDepChip(d, opts) {
    const target = findBead(d.id);
    const chip = el('span', {
      class: 'chip chip-existing',
      title: (target ? target.title : d.id) + '  ·  type: ' + d.type,
      'data-id': d.id,
      'data-type': d.type,
    });
    // Clickable bead id → jump to that bead's modal
    const link = el('a', {
      class: 'dep-chip-id',
      href: '#',
      onclick: (e) => { e.preventDefault(); openBeadModal(d.id); },
    }, d.id);
    chip.appendChild(link);
    if (d.type !== 'blocks') {
      const tag = el('span', { class: 'chip-type-tag' }, d.type);
      chip.appendChild(tag);
    }
    const rm = el('button', {
      type: 'button', class: 'chip-rm',
      'aria-label': 'Remove ' + d.id,
    }, '×');
    rm.addEventListener('click', async () => {
      rm.disabled = true;
      opts.statusLine.classList.remove('is-error');
      opts.statusLine.textContent = 'Removing dep…';
      try {
        const r = await window.__nppBridge.call('depRemove', {
          dependent:  d.dependent,
          dependency: d.dependency,
        });
        if (r.ok) {
          opts.statusLine.textContent = '';
          opts.onChanged();
        } else {
          opts.statusLine.textContent = r.error || 'dep remove failed';
          opts.statusLine.classList.add('is-error');
          rm.disabled = false;
        }
      } catch (e) {
        opts.statusLine.textContent = (e && e.message) || String(e);
        opts.statusLine.classList.add('is-error');
        rm.disabled = false;
      }
    });
    chip.appendChild(rm);
    return chip;
  }

  function escCloser(e) { if (e.key === 'Escape') closeBeadModal(); }

  function closeBeadModal() {
    const m = document.getElementById('bead-modal');
    if (m) m.remove();
    document.removeEventListener('keydown', escCloser);
  }

  // ── Render ──────────────────────────────────────────────────────────
  function buildCard(b) {
    const node = cardTpl.content.firstElementChild.cloneNode(true);
    node.dataset.beadId = b.id;
    node.querySelector('.card-type').textContent = App.typeIcon(b.type);
    node.querySelector('.card-type').title = b.type;
    const idA = node.querySelector('.card-id');
    idA.textContent = b.id;
    idA.href = '#/issue/' + encodeURIComponent(b.id);

    const title = node.querySelector('.card-title');
    title.textContent = b.title || '(no title)';
    title.title = b.title || '';

    const meta = node.querySelector('.card-meta');
    meta.innerHTML = '';

    const p = App.priorityBadge(b.priority);
    if (p) {
      const sp = document.createElement('span');
      sp.className = 'pill';
      sp.style.background = p.color;
      sp.style.color = '#fff';
      sp.textContent = p.label;
      meta.appendChild(sp);
    }
    if (b.assignee) {
      const sp = document.createElement('span');
      sp.className = 'meta-assignee';
      sp.textContent = '@' + b.assignee;
      meta.appendChild(sp);
    }
    if (b.sourceRepo) {
      const sp = document.createElement('span');
      sp.className = 'pill pill-source-repo';
      sp.textContent = App.sourceRepoLabel(b.sourceRepo);
      sp.title = 'source: ' + b.sourceRepo;   // full path on hover
      meta.appendChild(sp);
    }
    const labelsToShow = b.labels.slice(0, 3);
    for (const l of labelsToShow) {
      const sp = document.createElement('span');
      sp.className = 'pill pill-label';
      sp.style.borderColor = App.labelColor(l);
      sp.style.color       = App.labelColor(l);
      sp.textContent = l;
      meta.appendChild(sp);
    }
    if (b.labels.length > labelsToShow.length) {
      const sp = document.createElement('span');
      sp.className = 'meta-more';
      sp.textContent = '+' + (b.labels.length - labelsToShow.length);
      meta.appendChild(sp);
    }

    node.addEventListener('dragstart', onDragStart);
    node.addEventListener('dragend',   onDragEnd);
    node.addEventListener('click',     onCardClick);
    return node;
  }

  function buildColumn(cfg, items, unfilteredCount) {
    const node = colTpl.content.firstElementChild.cloneNode(true);
    node.dataset.status = cfg.status;
    node.classList.add('col-' + cfg.status);
    if (collapsed.has(cfg.status)) node.classList.add('is-collapsed');

    node.querySelector('.col-title').textContent = cfg.label;
    const countEl = node.querySelector('.col-count');
    if (App.filter.query && unfilteredCount !== items.length) {
      countEl.textContent = items.length + '/' + unfilteredCount;
    } else {
      countEl.textContent = String(items.length);
    }

    node.querySelector('.col-hdr').addEventListener('click', onToggleCol);
    node.addEventListener('dragover',  onDragOver);
    node.addEventListener('dragleave', onDragLeave);
    node.addEventListener('drop',      onDrop);

    const body = node.querySelector('.col-body');
    if (items.length === 0) {
      const empty = document.createElement('div');
      empty.className = 'col-empty';
      empty.textContent = App.filter.query && unfilteredCount > 0
        ? 'no match (' + unfilteredCount + ' filtered)'
        : 'no items';
      body.appendChild(empty);
    } else {
      // Cap rendering at 200 cards/col — agents can spam create, and
      // rendering 10k nodes kills scroll perf. Users can search to
      // narrow.
      const cap = Math.min(items.length, 200);
      for (let i = 0; i < cap; i++) body.appendChild(buildCard(items[i]));
      if (cap < items.length) {
        const more = document.createElement('div');
        more.className = 'col-empty';
        more.textContent = '… +' + (items.length - cap) + ' more (use search)';
        body.appendChild(more);
      }
    }
    return node;
  }

  function unfilteredCounts() {
    const out = { open: 0, in_progress: 0, blocked: 0, closed: 0 };
    for (const b of App.beads) {
      const s = effectiveStatus(b);
      if (out.hasOwnProperty(s)) out[s]++;
    }
    return out;
  }

  function render() {
    const grouped   = groupByStatus(App.beads);
    const unCounts  = unfilteredCounts();
    boardEl.innerHTML = '';
    for (const cfg of COLUMNS) {
      const items = grouped[cfg.status] || [];
      boardEl.appendChild(buildColumn(cfg, items, unCounts[cfg.status]));
    }
  }

  // ── Toast ───────────────────────────────────────────────────────────
  let toastTimer = null;
  function showToast(text) {
    let el = document.getElementById('toast');
    if (!el) {
      el = document.createElement('div');
      el.id = 'toast';
      el.className = 'toast';
      document.body.appendChild(el);
    }
    el.textContent = text;
    el.classList.add('toast-visible');
    if (toastTimer) clearTimeout(toastTimer);
    toastTimer = setTimeout(() => {
      el.classList.remove('toast-visible');
    }, 3500);
  }

  // ── New issue modal ─────────────────────────────────────────────────
  // Tiny inline form that posts `createBead` through the native bridge.
  // Kept self-contained so the Board view doesn't need to know about the
  // Rich/Issues views (they can grow their own entry points later).
  function openNewIssueModal() {
    closeNewIssueModal();
    const tpl = document.getElementById('new-issue-tpl');
    if (!tpl) return;
    const frag = tpl.content.firstElementChild.cloneNode(true);
    document.body.appendChild(frag);

    const overlay  = document.getElementById('new-issue-overlay');
    const form     = overlay.querySelector('.new-issue-form');
    const closeBtn = overlay.querySelector('.modal-close');
    const cancel   = overlay.querySelector('.new-issue-cancel');
    const submit   = overlay.querySelector('.new-issue-submit');
    const statusEl = overlay.querySelector('.form-status');
    const titleEl  = overlay.querySelector('input[name="title"]');

    // Dep chip-inputs: one for "Blocked by" (upstream), one for "Blocks"
    // (downstream). The shared <datalist id="dep-suggest"> lives in the
    // permanent body (board.html) so the detail-modal dep editor can use
    // the same autocomplete pool without re-defining it.
    refreshDepSuggestions();

    // Wires a chip-input region. Returns an object with `values()` that
    // yields [{id, type}, …] so the caller can build per-chip dep writes.
    //
    // If the region has a <span data-role="type-slot"></span> we mount a
    // dep-type <select> into it — chips created while the select shows
    // "blocks" record type=blocks, chips created while it shows
    // "parent-child" record type=parent-child, etc. Chip type is locked
    // at add time (visible in the chip's little tag suffix).
    function wireChipInput(containerRole) {
      const root = overlay.querySelector('[data-role="' + containerRole + '"]');
      const list = root.querySelector('.chip-list');
      const inp  = root.querySelector('input');
      const slot = root.querySelector('[data-role="type-slot"]');
      let typeSel = null;
      if (slot && typeof App.buildDepTypeSelect === 'function') {
        typeSel = App.buildDepTypeSelect('blocks');
        slot.appendChild(typeSel);
      }
      const entries = new Map();   // id → type
      function addChip(id) {
        id = String(id || '').trim();
        if (!id || entries.has(id)) return;
        const type = typeSel ? typeSel.value : 'blocks';
        entries.set(id, type);
        const bead = App.beads.find(b => b.id === id);
        const chip = document.createElement('span');
        chip.className = 'chip';
        chip.dataset.id = id;
        chip.dataset.type = type;
        chip.title = (bead ? bead.title : id) + '  ·  type: ' + type;
        chip.textContent = id;
        if (type !== 'blocks') {
          // Visually distinguish non-default types so the user can see
          // at a glance which chips will create which kind of dep.
          const tag = document.createElement('span');
          tag.className = 'chip-type-tag';
          tag.textContent = type;
          chip.appendChild(tag);
        }
        const rm = document.createElement('button');
        rm.type = 'button';
        rm.className = 'chip-rm';
        rm.textContent = '×';
        rm.setAttribute('aria-label', 'Remove ' + id);
        rm.addEventListener('click', () => { entries.delete(id); chip.remove(); });
        chip.appendChild(rm);
        list.appendChild(chip);
      }
      inp.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' || e.key === ',' || e.key === 'Tab') {
          const v = inp.value.trim().replace(/,$/, '');
          if (v) { e.preventDefault(); addChip(v); inp.value = ''; }
        } else if (e.key === 'Backspace' && !inp.value) {
          const chips = list.querySelectorAll('.chip');
          if (chips.length) {
            const last = chips[chips.length - 1];
            entries.delete(last.dataset.id);
            last.remove();
          }
        }
      });
      inp.addEventListener('change', () => {
        const v = inp.value.trim();
        if (v) { addChip(v); inp.value = ''; }
      });
      return {
        values() {
          const out = [];
          for (const [id, type] of entries) out.push({ id, type });
          return out;
        },
      };
    }
    const blockerInput = wireChipInput('blockers');
    const blocksInput  = wireChipInput('blocks');

    overlay.addEventListener('click', (e) => {
      if (e.target === overlay) closeNewIssueModal();
    });
    closeBtn.addEventListener('click', closeNewIssueModal);
    cancel.addEventListener('click', closeNewIssueModal);
    document.addEventListener('keydown', newIssueEscHandler);

    form.addEventListener('submit', (e) => {
      e.preventDefault();
      const title = titleEl.value.trim();
      if (!title) {
        statusEl.textContent = 'Title is required';
        statusEl.classList.add('is-error');
        titleEl.focus();
        return;
      }
      const data = new FormData(form);
      const labelsRaw = (data.get('labels') || '').toString();
      const labels = labelsRaw.split(',').map(s => s.trim()).filter(Boolean);
      const payload = {
        title,
        issueType:   (data.get('issueType') || 'task').toString(),
        priority:    parseInt(data.get('priority'), 10),
        description: (data.get('description') || '').toString(),
        labels,
      };
      submit.disabled = true;
      statusEl.classList.remove('is-error');
      statusEl.textContent = 'Creating…';

      if (!window.__nppBridge) {
        statusEl.textContent = 'native bridge unavailable';
        statusEl.classList.add('is-error');
        submit.disabled = false;
        return;
      }
      const blockerEntries = blockerInput.values();   // blocking the new issue
      const blocksEntries  = blocksInput.values();    // new issue blocks these
      window.__nppBridge.call('createBead', payload).then(async (resp) => {
        if (!resp.ok) {
          statusEl.textContent = resp.error || 'create failed';
          statusEl.classList.add('is-error');
          submit.disabled = false;
          return;
        }
        const newId = resp.bead && resp.bead.id;
        if (!newId) {
          showToast('issue created');
          closeNewIssueModal();
          return;
        }
        // Sequential dep writes — bd's embedded dolt backend can deadlock
        // on concurrent writes within the same project. Each dep is:
        //   Blocked-by chip: newId depends on chipId   (chipId blocks newId)
        //   Blocks      chip: chipId depends on newId  (newId blocks chipId)
        // Each chip now carries its own dep type (Phase 3.5).
        const totalDeps = blockerEntries.length + blocksEntries.length;
        const failed = [];
        async function postDep(dependent, dependency, depType) {
          try {
            const r = await window.__nppBridge.call('depAdd', {
              dependent, dependency, depType: depType || 'blocks',
            });
            if (!r.ok) failed.push(dependent + '←' + dependency +
                                   ' (' + (r.error || 'failed') + ')');
          } catch (e) {
            failed.push(dependent + '←' + dependency +
                        ' (' + ((e && e.message) || e) + ')');
          }
        }
        if (totalDeps) {
          statusEl.textContent = 'linking ' + totalDeps + ' dep' +
                                 (totalDeps > 1 ? 's' : '') + '…';
          for (const e of blockerEntries) await postDep(newId, e.id, e.type);
          for (const e of blocksEntries)  await postDep(e.id, newId, e.type);
        }
        if (failed.length) {
          showToast(newId + ' created; some deps failed: ' + failed.join('; '));
        } else if (totalDeps) {
          showToast(newId + ' created with ' + totalDeps + ' dep' +
                    (totalDeps > 1 ? 's' : ''));
        } else {
          showToast(newId + ' created');
        }
        optimistic.set(newId, 'open');
        closeNewIssueModal();
      }).catch((err) => {
        statusEl.textContent = (err && err.message) || String(err);
        statusEl.classList.add('is-error');
        submit.disabled = false;
      });
    });

    // Focus the title field and let the user start typing immediately.
    setTimeout(() => titleEl.focus(), 0);
  }
  function closeNewIssueModal() {
    const overlay = document.getElementById('new-issue-overlay');
    if (overlay) overlay.remove();
    document.removeEventListener('keydown', newIssueEscHandler);
  }
  function newIssueEscHandler(e) {
    if (e.key === 'Escape') closeNewIssueModal();
  }
  (function wireNewIssueButton() {
    const btn = document.getElementById('new-issue-btn');
    if (btn) btn.addEventListener('click', openNewIssueModal);
  })();

  // ── Mode toggle wiring ──────────────────────────────────────────────
  function syncModeButtons() {
    const btns = document.querySelectorAll('#board-hdr .mode-btn');
    btns.forEach((b) => {
      const selected = b.dataset.mode === statusMode;
      b.setAttribute('aria-selected', selected ? 'true' : 'false');
    });
  }
  function onModeClick(e) {
    const m = e.currentTarget.dataset.mode;
    if (!m || m === statusMode) return;
    statusMode = m;
    saveMode(m);
    syncModeButtons();
    render();
  }
  function wireModeToggle() {
    const btns = document.querySelectorAll('#board-hdr .mode-btn');
    btns.forEach((b) => b.addEventListener('click', onModeClick));
    syncModeButtons();
  }
  wireModeToggle();

  // ── App wiring ──────────────────────────────────────────────────────
  App.onDataLoaded = render;

  // The actual refresh body, extracted so the drag-guard can defer +
  // replay it without duplicating logic.
  function _runRefresh() {
    // Real data arrived — drop every optimistic override, then render.
    // In Effective mode, if a card's computed state differs from the
    // column the user dragged it to, surface a toast so the snap-back
    // doesn't look like a silent no-op. We stash overrides before
    // clearing so the render-after-refresh shows truth, not stale
    // guesses.
    const prevOverrides = new Map(optimistic);
    optimistic.clear();
    if (statusMode === 'effective') {
      for (const [id, ov] of prevOverrides) {
        const b = App.beads.find(x => x.id === id);
        if (!b) continue;
        const eff = effectiveStatus(b);
        if (eff !== ov) {
          showToast(b.id + ' · shown in ' + App.statusColor(eff).label +
                    ' (has open blockers)');
          break;  // one toast per refresh is enough
        }
      }
    }
    render();
  }

  App.onRefresh = function () {
    if (isDraggingCard) {
      // Defer; dragend will flush. Swallow newer refreshes until then —
      // one final render after the drag is enough.
      pendingRefresh = true;
      return;
    }
    _runRefresh();
  };

  // ── Phase 5 — programmatic entry points from the native editor hooks ──
  // NppBeads.mm fires these after the user triggers
  //   Plugins → NppBeads → Jump to bead under caret (⌘⌥⇧J)
  //   Plugins → NppBeads → Create issue from selection (⌘⌥⇧N)
  // Either the panel was already on Board (JS runs immediately) or the
  // view was switched and this runs inside didFinishNavigation's
  // pending-JS hook. On first-open the JS may beat __nppApp — native
  // stashes `window.__nppBeadsPendingModalId` / `.pendingCreateTitle`
  // and we drain those here.

  App.openBeadModalById = function (id) {
    if (typeof id !== 'string' || !id) return;
    openBeadModal(id);
  };

  App.openNewIssueWithTitle = function (title) {
    openNewIssueModal();
    // Prefill on next tick — openNewIssueModal appends the template,
    // the title input is queryable immediately but we defer to be safe
    // with any Alpine/transition timing (there's no Alpine here but
    // this matches the pattern used for autofocus).
    setTimeout(function () {
      const overlay = document.getElementById('new-issue-overlay');
      if (!overlay) return;
      const input = overlay.querySelector('input[name="title"]');
      if (input && typeof title === 'string' && title.length) {
        input.value = title;
        // Move caret to end for easy editing
        input.setSelectionRange(title.length, title.length);
        input.focus();
      }
    }, 0);
  };

  // Drain any pending directives that native set before we loaded.
  (function drainPending() {
    if (typeof window.__nppBeadsPendingModalId === 'string') {
      const id = window.__nppBeadsPendingModalId;
      delete window.__nppBeadsPendingModalId;
      App.openBeadModalById(id);
    }
    if (typeof window.__nppBeadsPendingCreateTitle === 'string') {
      const title = window.__nppBeadsPendingCreateTitle;
      delete window.__nppBeadsPendingCreateTitle;
      App.openNewIssueWithTitle(title);
    }
  })();
  App.applyFilter  = render;

  // Initial render if data already present (app.js fires DOMContentLoaded
  // listener earlier in same file, but this view may register later).
  if (App.beads.length) render();
})();
