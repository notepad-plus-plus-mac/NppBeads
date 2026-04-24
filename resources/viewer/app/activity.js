// Beads Activity view — Phase 6.
//
// Flat list of issues sorted by updated_at DESC. Each row shows id /
// title / status / timestamp. Click → asks native to open the Board's
// detail modal on that bead (via the `openBeadModal` bridge message).
//
// Data source: window.__nppApp.beads (parsed JSONL). We don't fetch
// per-issue comment lists from here — that would be N bd calls per
// view-open. The detail modal does its own fetchBead, which is plenty.

(function () {
  'use strict';
  const App = window.__nppApp;
  if (!App) { console.warn('[Activity] __nppApp missing'); return; }

  const listEl = document.getElementById('activity-list');
  const sumEl  = document.getElementById('activity-summary');

  function render() {
    listEl.innerHTML = '';
    const beads = (App.beads || []).slice().sort((a, b) => {
      const tA = a.updatedAt || a.createdAt || '';
      const tB = b.updatedAt || b.createdAt || '';
      return String(tB).localeCompare(String(tA));
    });

    if (beads.length === 0) {
      const empty = document.createElement('div');
      empty.className = 'activity-empty';
      empty.textContent = 'No issues in this project yet.';
      listEl.appendChild(empty);
      sumEl.textContent = '';
      return;
    }

    // Apply the panel's search filter — same field as Board. Touches
    // the same App.filter so "search for foo" narrows both views.
    const q = (App.filter && App.filter.query) ? App.filter.query : '';
    let shown = 0;
    const cap = 200;   // render cap — agents can create 10k+ beads
    for (const b of beads) {
      if (q && !App.matchesQuery(b, q)) continue;
      if (shown >= cap) break;
      listEl.appendChild(buildRow(b));
      shown++;
    }
    sumEl.textContent = (shown === beads.length)
      ? (shown + ' issue' + (shown === 1 ? '' : 's'))
      : (shown + ' of ' + beads.length + ' shown');
    if (shown === 0 && q) {
      const none = document.createElement('div');
      none.className = 'activity-empty';
      none.textContent = 'No issues match the current search.';
      listEl.appendChild(none);
    }
  }

  function buildRow(b) {
    const row = document.createElement('div');
    row.className = 'activity-row';
    row.dataset.beadId = b.id;

    const idEl = document.createElement('a');
    idEl.className = 'activity-id';
    idEl.textContent = b.id;
    idEl.href = '#';
    idEl.addEventListener('click', (e) => {
      e.preventDefault();
      openBeadModal(b.id);
    });
    row.appendChild(idEl);

    const titleEl = document.createElement('div');
    titleEl.className = 'activity-title-cell';
    titleEl.textContent = b.title || '(no title)';
    titleEl.title = b.title || '';
    titleEl.addEventListener('click', () => openBeadModal(b.id));
    row.appendChild(titleEl);

    const metaEl = document.createElement('div');
    metaEl.className = 'activity-meta';

    const s = App.statusColor(b.status);
    const status = document.createElement('span');
    status.className = 'pill';
    status.style.background = s.bg;
    status.style.color      = s.fg;
    status.textContent = s.label;
    metaEl.appendChild(status);

    const p = App.priorityBadge(b.priority);
    if (p) {
      const pEl = document.createElement('span');
      pEl.className = 'pill';
      pEl.style.background = p.color;
      pEl.style.color = '#fff';
      pEl.textContent = p.label;
      metaEl.appendChild(pEl);
    }

    if (b.assignee) {
      const aEl = document.createElement('span');
      aEl.className = 'activity-assignee';
      aEl.textContent = '@' + b.assignee;
      metaEl.appendChild(aEl);
    }

    const when = document.createElement('span');
    when.className = 'activity-time';
    when.textContent = App.fmtTime(b.updatedAt || b.createdAt);
    metaEl.appendChild(when);

    row.appendChild(metaEl);
    return row;
  }

  // Ask native to open the Board's detail modal for `id`. This is a
  // fire-and-forget bridge message — no reqId, no Promise. The native
  // handler routes through showBeadDetail: which switches the view and
  // queues the JS that opens the modal.
  function openBeadModal(id) {
    if (!id) return;
    if (window.webkit && window.webkit.messageHandlers &&
        window.webkit.messageHandlers.beadsBridge) {
      try {
        window.webkit.messageHandlers.beadsBridge.postMessage({
          type: 'openBeadModal', id,
        });
      } catch (e) { console.warn('[Activity] bridge post failed:', e); }
    }
  }

  App.onDataLoaded = render;
  App.onRefresh    = render;
  App.applyFilter  = render;

  if (App.beads && App.beads.length) render();
})();
