// Beads Activity view — Phase 6.
//
// Flat scrollable list of issues sorted by updated_at DESC. Each row
// stays compact by default; hovering expands an inline preview with
// description + extra metadata (labels / dep counts / type). A
// dedicated "Open" button (visible on hover) is the ONLY click path
// into the Board detail modal — row body / title / id are not clickable.
//
// Data source: window.__nppApp.beads (parsed from JSONL). We don't
// fetch per-issue records here — the panel's Board-side detail modal
// does its own fetchBead on open.

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

    const main = document.createElement('div');
    main.className = 'activity-row-main';

    const idEl = document.createElement('span');
    idEl.className = 'activity-id';
    idEl.textContent = b.id;
    idEl.title = b.id;   // tooltip lets user see full id even when narrow
    main.appendChild(idEl);

    const titleEl = document.createElement('div');
    titleEl.className = 'activity-title-cell';
    titleEl.textContent = b.title || '(no title)';
    titleEl.title = b.title || '';
    main.appendChild(titleEl);

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
    when.title = b.updatedAt || b.createdAt || '';
    metaEl.appendChild(when);

    // Open button — only click path into the Board detail modal. Hidden
    // by CSS until the row is hovered / focused, so compact rows stay
    // compact when the user is just scanning.
    const openBtn = document.createElement('button');
    openBtn.type = 'button';
    openBtn.className = 'activity-open-btn';
    openBtn.textContent = 'Open ↗';
    openBtn.title = 'Open in Board detail view (' + b.id + ')';
    openBtn.addEventListener('click', (e) => {
      e.stopPropagation();
      requestOpenInBoard(b.id);
    });
    metaEl.appendChild(openBtn);

    main.appendChild(metaEl);
    row.appendChild(main);

    // Hover preview — pre-rendered so there's no lag on first hover.
    row.appendChild(buildPreview(b));

    return row;
  }

  function buildPreview(b) {
    const wrap = document.createElement('div');
    wrap.className = 'activity-preview';

    // Description — truncated to keep the expanded row bounded.
    const descRaw = (typeof b.description === 'string') ? b.description : '';
    if (descRaw.trim().length) {
      const body = document.createElement('div');
      body.className = 'activity-preview-body';
      const shortTxt = descRaw.length > 600 ? descRaw.slice(0, 600) + '…' : descRaw;
      // Preview stays plain-text so the row layout can't be broken by
      // someone pasting raw HTML inside a description. Whitespace is
      // preserved via CSS `white-space: pre-wrap` — keeps bullet lists
      // and indented code legible without running our markdown renderer
      // (which would style too heavily for a compact preview).
      body.textContent = shortTxt;
      if (descRaw.length > 600) body.classList.add('is-truncated');
      wrap.appendChild(body);
    } else {
      const empty = document.createElement('p');
      empty.className = 'activity-preview-empty';
      empty.textContent = '(no description)';
      wrap.appendChild(empty);
    }

    // Facts row — quick overview of type, label count, dep counts, etc.
    const facts = document.createElement('div');
    facts.className = 'activity-preview-facts';

    function addFact(key, val) {
      if (val === null || val === undefined || val === '') return;
      const f = document.createElement('span');
      const k = document.createElement('span');
      k.className = 'fact-key';
      k.textContent = key + ':';
      const v = document.createElement('span');
      v.className = 'fact-val';
      v.textContent = ' ' + val;
      f.appendChild(k);
      f.appendChild(v);
      facts.appendChild(f);
    }

    addFact('type', b.type || null);
    if (b.labels && b.labels.length) {
      addFact('labels', b.labels.slice(0, 6).join(', ') +
        (b.labels.length > 6 ? ` (+${b.labels.length - 6})` : ''));
    }

    // Dep counts — deps is the raw `dependencies` array from the JSONL
    // record (we normalize to .deps in app.js). Each entry has
    // issue_id / depends_on_id / type.
    const deps = Array.isArray(b.deps) ? b.deps : [];
    let blockedByN = 0, blocksN = 0;
    for (const d of deps) {
      if (d && d.issue_id === b.id)           blockedByN++;
      else if (d && d.depends_on_id === b.id) blocksN++;
    }
    if (blockedByN) addFact('blocked by', blockedByN);
    if (blocksN)    addFact('blocks',     blocksN);

    if (b.sourceRepo) addFact('source', App.sourceRepoLabel(b.sourceRepo));

    wrap.appendChild(facts);
    return wrap;
  }

  // Ask native to open the Board's detail modal for `id`. Fire-and-
  // forget — no reqId, no Promise. The native handler routes through
  // showBeadDetail: which switches the view and queues the JS.
  function requestOpenInBoard(id) {
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
