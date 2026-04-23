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
    return ov || b.status;
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
  function onDragStart(e) {
    const id = e.currentTarget.dataset.beadId;
    if (!id) return;
    e.dataTransfer.setData('text/plain', id);
    e.dataTransfer.effectAllowed = 'move';
    e.currentTarget.classList.add('card-dragging');
  }
  function onDragEnd(e) {
    e.currentTarget.classList.remove('card-dragging');
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
    if (effectiveStatus(bead) === newStatus) return;

    // Optimistic move: reflect new status immediately; native round-trip
    // happens in Phase 3 (bd update). For Phase 2 the optimistic status
    // persists until the page reloads — we surface a small toast so
    // users know it's not yet persisted.
    optimistic.set(beadId, newStatus);
    showToast(
      'Moved "' + bead.id + '" to ' + App.statusColor(newStatus).label +
      ' — editing requires `bd` (coming in Phase 3)'
    );
    App.postNative({ type: 'updateBead', id: beadId, status: newStatus });
    render();
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

    const card = el('div', { class: 'modal-card' });

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

    // Title
    card.appendChild(el('h2', { class: 'modal-title' }, b.title || '(no title)'));

    // Status/priority/type/assignee row
    card.appendChild(buildPills(b));

    // Labels
    const lab = buildLabels(b.labels);
    if (lab) card.appendChild(lab);

    // Body — description + deps + timestamps
    const body = el('div', { class: 'modal-body' });
    if (b.description) {
      body.appendChild(el('div', { class: 'modal-desc' }, b.description));
    }
    const deps = buildDeps(b);
    if (deps) body.appendChild(deps);

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

    card.appendChild(body);
    overlay.appendChild(card);
    document.body.appendChild(overlay);

    // Esc to close
    document.addEventListener('keydown', escCloser);
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

  // ── App wiring ──────────────────────────────────────────────────────
  App.onDataLoaded = render;
  App.onRefresh    = function () {
    // Real data arrived — clear any optimistic overrides that match.
    for (const [id, st] of [...optimistic]) {
      const b = App.beads.find(x => x.id === id);
      if (!b || b.status === st) optimistic.delete(id);
    }
    render();
  };
  App.applyFilter  = render;

  // Initial render if data already present (app.js fires DOMContentLoaded
  // listener earlier in same file, but this view may register later).
  if (App.beads.length) render();
})();
