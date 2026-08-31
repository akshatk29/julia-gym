/* ==========================================================================
   Julia Gym — frontend.

   No build step, no framework, no npm (§2). CodeMirror is loaded from
   public/vendor/ and degrades to a plain textarea if it isn't there, so an
   unreachable CDN can never make the app unusable.
   ========================================================================== */

'use strict';

const $ = (id) => document.getElementById(id);

const state = {
  puzzles: [],
  current: null,     // the loaded detail object
  editor: null,      // { getValue, setValue, focus }
  running: false,
  hintsShown: 0,
  saveTimer: null,
};

/* --- API ----------------------------------------------------------------- */

async function api(path, opts) {
  const res = await fetch(path, opts);
  let data = null;
  try { data = await res.json(); } catch (_) { /* fall through to status */ }
  if (!res.ok) {
    const msg = (data && data.error) || `Request failed (${res.status})`;
    const err = new Error(msg);
    err.status = res.status;
    throw err;
  }
  return data;
}

const getJSON  = (p)       => api(p);
const postJSON = (p, body) => api(p, {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify(body),
});

/* --- Markdown ------------------------------------------------------------
   A small renderer rather than a vendored library: problem.md is short,
   controlled content that we author ourselves, so this covers it and keeps the
   vendor surface to the editor alone. */

function escapeHTML(s) {
  return s.replace(/[&<>"']/g, (c) => (
    { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]
  ));
}

function inlineMD(s) {
  let out = escapeHTML(s);
  out = out.replace(/`([^`]+)`/g, '<code>$1</code>');
  out = out.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
  out = out.replace(/(^|[\s(])\*([^*\n]+)\*/g, '$1<em>$2</em>');
  return out;
}

function renderMarkdown(md) {
  const lines = md.replace(/\r\n/g, '\n').split('\n');
  const out = [];
  let i = 0;

  while (i < lines.length) {
    const line = lines[i];

    if (/^```/.test(line)) {                       // fenced code
      const buf = [];
      i++;
      while (i < lines.length && !/^```/.test(lines[i])) buf.push(lines[i++]);
      i++;
      out.push(`<pre><code>${escapeHTML(buf.join('\n'))}</code></pre>`);
      continue;
    }
    if (/^#{1,6}\s/.test(line)) {                  // heading
      out.push(`<h3>${inlineMD(line.replace(/^#{1,6}\s+/, ''))}</h3>`);
      i++;
      continue;
    }
    if (/^\s*[-*]\s+/.test(line)) {                // list
      const items = [];
      while (i < lines.length && /^\s*[-*]\s+/.test(lines[i])) {
        items.push(`<li>${inlineMD(lines[i].replace(/^\s*[-*]\s+/, ''))}</li>`);
        i++;
      }
      out.push(`<ul>${items.join('')}</ul>`);
      continue;
    }
    if (line.trim() === '') { i++; continue; }

    const buf = [];                                // paragraph
    while (i < lines.length && lines[i].trim() !== '' &&
           !/^```/.test(lines[i]) && !/^#{1,6}\s/.test(lines[i]) &&
           !/^\s*[-*]\s+/.test(lines[i])) {
      buf.push(lines[i++]);
    }
    const text = buf.join(' ');
    // The "Julia note" gets its own treatment — it's the one teaching line
    // each problem is allowed (§9).
    const cls = /^\*\*Julia note:?\*\*/.test(text) ? ' class="julia-note"' : '';
    out.push(`<p${cls}>${inlineMD(text)}</p>`);
  }
  return out.join('\n');
}

/* --- Editor -------------------------------------------------------------- */

function makeEditor(host) {
  if (typeof CodeMirror === 'function') {
    const cm = CodeMirror(host, {
      value: '',
      mode: 'julia',
      lineNumbers: true,
      indentUnit: 4,
      tabSize: 4,
      indentWithTabs: false,
      matchBrackets: true,
      autoCloseBrackets: true,
      lineWrapping: false,
      extraKeys: {
        'Cmd-Enter': runSubmission,
        'Ctrl-Enter': runSubmission,
        Tab: (cm) => cm.somethingSelected()
          ? cm.indentSelection('add')
          : cm.replaceSelection('    ', 'end'),
      },
    });
    cm.on('change', scheduleDraftSave);
    return {
      getValue: () => cm.getValue(),
      setValue: (v) => { cm.setValue(v); cm.clearHistory(); },
      focus: () => cm.focus(),
      refresh: () => cm.refresh(),
    };
  }

  // Degraded path: a styled textarea with tab-to-indent (§2).
  const ta = document.createElement('textarea');
  ta.className = 'fallback-editor';
  ta.spellcheck = false;
  ta.setAttribute('aria-label', 'Julia code');
  host.appendChild(ta);
  ta.addEventListener('input', scheduleDraftSave);
  ta.addEventListener('keydown', (e) => {
    if (e.key === 'Tab') {
      e.preventDefault();
      const s = ta.selectionStart, t = ta.selectionEnd;
      ta.value = ta.value.slice(0, s) + '    ' + ta.value.slice(t);
      ta.selectionStart = ta.selectionEnd = s + 4;
    } else if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
      e.preventDefault();
      runSubmission();
    }
  });
  return {
    getValue: () => ta.value,
    setValue: (v) => { ta.value = v; },
    focus: () => ta.focus(),
    refresh: () => {},
  };
}

/* --- Rail ---------------------------------------------------------------- */

function renderRail() {
  const list = $('rail-list');
  list.innerHTML = '';
  for (const p of state.puzzles) {
    const btn = document.createElement('button');
    btn.className = 'rail-item';
    btn.type = 'button';
    if (state.current && state.current.id === p.id) btn.setAttribute('aria-current', 'true');

    // A clean solve — no hints, no peek — earns the full three-dot mark.
    if (p.clean) {
      const m = document.createElement('span');
      m.className = 'pip-clean';
      m.title = 'Solved with no hints';
      m.innerHTML = '<i></i><i></i><i></i>';
      btn.appendChild(m);
    } else {
      const pip = document.createElement('span');
      pip.className = 'pip' + (p.solved ? ' solved' : '');
      pip.title = p.solved ? 'Solved' : 'Unsolved';
      btn.appendChild(pip);
    }

    const t = document.createElement('span');
    t.className = 'rail-title';
    t.textContent = p.title;
    btn.appendChild(t);

    const tag = document.createElement('span');
    tag.className = 'track-tag';
    tag.textContent = p.track.slice(0, 3);
    btn.appendChild(tag);

    btn.addEventListener('click', () => selectPuzzle(p.id));
    list.appendChild(btn);
  }

  const solved = state.puzzles.filter((p) => p.solved).length;
  $('tally').textContent = `${solved} / ${state.puzzles.length} solved`;
}

/* --- Problem pane -------------------------------------------------------- */

function renderProblem(d) {
  const el = $('problem');
  el.innerHTML = '';

  const h = document.createElement('h2');
  h.textContent = d.title;
  el.appendChild(h);

  const meta = document.createElement('div');
  meta.className = 'meta-row';
  const dots = [1, 2, 3].map((n) => `<i class="${n <= d.difficulty ? 'on' : ''}"></i>`).join('');
  meta.innerHTML =
    `<span>${escapeHTML(d.track)}</span>` +
    `<span class="difficulty" title="Difficulty ${d.difficulty} of 3">${dots}</span>` +
    (d.solved ? '<span style="color:var(--pass-text)">solved</span>' : '');
  el.appendChild(meta);

  const prose = document.createElement('div');
  prose.className = 'prose';
  prose.innerHTML = renderMarkdown(d.problem);
  el.appendChild(prose);

  if (d.cases && d.cases.length) {
    const lbl = document.createElement('div');
    lbl.className = 'section-label';
    lbl.textContent = `Examples${d.hidden_count ? ` · plus ${d.hidden_count} hidden case${d.hidden_count > 1 ? 's' : ''}` : ''}`;
    el.appendChild(lbl);

    const wrap = document.createElement('div');
    wrap.className = 'examples';
    for (const c of d.cases) {
      const row = document.createElement('div');
      row.className = 'example';
      row.innerHTML =
        `<div><span class="k">${escapeHTML(d.entrypoint)}(…)</span><span class="v">${escapeHTML(c.input)}</span></div>` +
        `<div><span class="k">returns</span><span class="v">${escapeHTML(c.expected)}</span></div>`;
      wrap.appendChild(row);
    }
    el.appendChild(wrap);
  }

  if (d.teaches && d.teaches.length) {
    const lbl = document.createElement('div');
    lbl.className = 'section-label';
    lbl.textContent = 'What it teaches';
    el.appendChild(lbl);
    const t = document.createElement('div');
    t.className = 'teaches';
    t.innerHTML = d.teaches.map((x) => `<span>${escapeHTML(x)}</span>`).join('');
    el.appendChild(t);
  }

  $('fn-name').innerHTML = `define <b>${escapeHTML(d.entrypoint)}</b>`;
  $('hint-btn').disabled = d.hint_count === 0;
  $('hint-btn').textContent = d.hint_count ? `Hint (${d.hint_count})` : 'Hint';
}

/* --- Results ------------------------------------------------------------- */

function caseNode(c, index) {
  const div = document.createElement('div');
  div.className = 'case ' + (c.pass ? 'pass' : 'fail');
  div.style.animationDelay = (index * 60) + 'ms';   // ~60ms stagger (§8)

  const head = document.createElement('div');
  head.className = 'case-head';
  head.innerHTML =
    `<span class="mark">${c.pass ? '✓' : '✗'}</span>` +
    `<span class="lbl">case ${index + 1}</span>` +
    (c.hidden ? '<span class="badge-hidden">hidden</span>' : '') +
    `<span class="us">${c.elapsed_us != null ? c.elapsed_us.toLocaleString() + ' µs' : ''}</span>`;
  div.appendChild(head);

  // A passing case needs no detail; a failing one shows everything, aligned.
  if (!c.pass || c.stdout) {
    const body = document.createElement('div');
    body.className = 'case-body';

    const row = (cls, k, v) => {
      const r = document.createElement('div');
      r.className = 'kv ' + cls;
      r.innerHTML = `<span class="k">${k}</span><span class="v">${escapeHTML(v)}</span>`;
      body.appendChild(r);
    };

    if (!c.pass) {
      row('', 'input', c.input);
      // A hidden case reveals pass/fail and its input, never its expectation.
      row('want', 'expected', c.expected === null ? '(hidden)' : c.expected);
      row('got', 'got', c.got);
    }
    if (c.stdout) {
      row('out', 'printed', c.stdout + (c.truncated ? '\n… output truncated at 64 KB' : ''));
    }
    if (c.note) {
      const n = document.createElement('p');
      n.className = 'note';
      n.textContent = c.note;
      body.insertBefore(n, body.firstChild);
    }
    if (c.error) {
      const e = document.createElement('p');
      e.className = 'err';
      e.textContent = c.error.message;
      if (c.error.frames && c.error.frames.length) {
        const f = document.createElement('span');
        f.className = 'frames';
        f.textContent = 'in ' + c.error.frames.join(' · ');
        e.appendChild(f);
      }
      body.appendChild(e);
    }
    div.appendChild(body);
  }
  return div;
}

function renderResults(r) {
  const el = $('results');
  el.innerHTML = '';

  // A whole-run failure (timeout, syntax error, missing function) is a banner,
  // not a case list — there are no cases to show.
  if (r.error) {
    const b = document.createElement('div');
    b.className = 'banner fail';
    b.textContent = r.error.message;
    el.appendChild(b);
    if (r.error.frames && r.error.frames.length) {
      const f = document.createElement('div');
      f.className = 'empty';
      f.textContent = 'in ' + r.error.frames.join(' · ');
      el.appendChild(f);
    }
    if (!r.cases || !r.cases.length) return;
  }

  const passed = r.cases.filter((c) => c.pass).length;
  const head = document.createElement('div');
  head.className = 'results-head';
  head.innerHTML =
    `<span class="verdict ${r.ok ? 'pass' : 'fail'}">${r.ok ? 'All passing' : `${passed} of ${r.cases.length} passing`}</span>` +
    `<span class="timing">${r.wall_ms} ms</span>`;
  el.appendChild(head);

  if (r.ok) {
    const b = document.createElement('div');
    b.className = 'banner pass';
    b.textContent = 'Solved. Pick the next puzzle from the rail.';
    el.appendChild(b);
  }

  r.cases.forEach((c, i) => el.appendChild(caseNode(c, i)));
}

/* --- Actions ------------------------------------------------------------- */

function setRunning(on) {
  state.running = on;
  const b = $('run-btn');
  b.disabled = on;
  b.classList.toggle('running', on);
  b.innerHTML = on ? 'Running…' : 'Run<kbd>⌘↵</kbd>';
}

async function runSubmission() {
  if (state.running || !state.current) return;
  setRunning(true);
  $('results').innerHTML = '<div class="banner running">Running against the real Julia…</div>';
  try {
    const r = await postJSON('/api/run', {
      puzzle: state.current.id,
      code: state.editor.getValue(),
    });
    renderResults(r);
    if (r.solved) await refreshPuzzles();
  } catch (e) {
    $('results').innerHTML = '';
    const b = document.createElement('div');
    b.className = 'banner fail';
    b.textContent = e.message;
    $('results').appendChild(b);
  } finally {
    setRunning(false);
  }
}

function scheduleDraftSave() {
  clearTimeout(state.saveTimer);
  state.saveTimer = setTimeout(async () => {
    if (!state.current) return;
    try {
      await postJSON(`/api/puzzles/${encodeURIComponent(state.current.id)}/draft`,
                     { code: state.editor.getValue() });
    } catch (_) { /* a failed autosave should never interrupt typing */ }
  }, 800);
}

/* --- Panels -------------------------------------------------------------- */

function closePanel() { $('panel-scrim').hidden = true; }

function openPanel(title, sub, buildBody, actions) {
  $('panel-title').textContent = title;
  $('panel-sub').textContent = sub;
  const body = $('panel-body');
  body.innerHTML = '';
  buildBody(body);
  const bar = $('panel-actions');
  bar.innerHTML = '';
  for (const a of actions) {
    const b = document.createElement('button');
    b.className = 'btn' + (a.primary ? ' primary' : '');
    b.textContent = a.label;
    b.addEventListener('click', a.onClick);
    bar.appendChild(b);
  }
  $('panel-scrim').hidden = false;
  bar.querySelector('button') && bar.querySelector('button').focus();
}

async function showHints() {
  const d = state.current;
  if (!d || !d.hint_count) return;
  const want = Math.min(state.hintsShown + 1, d.hint_count);
  const hints = [];
  for (let n = 1; n <= want; n++) {
    hints.push(await getJSON(`/api/puzzles/${encodeURIComponent(d.id)}/hint?n=${n}`));
  }
  state.hintsShown = want;
  const remaining = d.hint_count - want;

  openPanel('Hint', `${want} of ${d.hint_count} shown`, (body) => {
    for (const h of hints) {
      const p = document.createElement('p');
      p.className = 'hint-item';
      p.textContent = h.hint;
      body.appendChild(p);
    }
    const note = document.createElement('p');
    note.className = 'empty';
    note.style.margin = '0';
    note.textContent = remaining
      ? `${remaining} more hint${remaining > 1 ? 's' : ''} available.`
      : 'That was the last hint.';
    body.appendChild(note);
  }, [
    ...(remaining ? [{ label: 'Next hint', onClick: showHints }] : []),
    { label: 'Close', primary: true, onClick: closePanel },
  ]);
  refreshPuzzles();
}

function confirmSolution() {
  const d = state.current;
  if (!d) return;
  openPanel('Show the reference solution?', 'this is recorded on your progress', (body) => {
    const p = document.createElement('p');
    p.style.margin = '0';
    p.textContent = d.solved
      ? 'You have already solved this one — comparing approaches is the point.'
      : 'Once seen, this puzzle is marked as solved with help. There is no undo.';
    body.appendChild(p);
  }, [
    { label: 'Cancel', onClick: closePanel },
    { label: 'Show it', primary: true, onClick: async () => {
        const r = await getJSON(`/api/puzzles/${encodeURIComponent(d.id)}/solution`);
        openPanel(d.title, 'reference solution', (body) => {
          const pre = document.createElement('pre');
          pre.textContent = r.solution.trimEnd();
          body.appendChild(pre);
        }, [
          { label: 'Load into editor', onClick: () => {
              state.editor.setValue(r.solution.trimEnd());
              closePanel();
              scheduleDraftSave();
            } },
          { label: 'Close', primary: true, onClick: closePanel },
        ]);
        refreshPuzzles();
      } },
  ]);
}

function confirmReset() {
  openPanel('Clear all progress?', 'solves, drafts, hints and timings', (body) => {
    const p = document.createElement('p');
    p.style.margin = '0';
    p.textContent = 'Every puzzle goes back to unsolved and every draft is deleted. This cannot be undone.';
    body.appendChild(p);
  }, [
    { label: 'Cancel', onClick: closePanel },
    { label: 'Clear everything', primary: true, onClick: async () => {
        await postJSON('/api/reset', {});
        closePanel();
        await refreshPuzzles();
        if (state.current) await selectPuzzle(state.current.id);
        toast('Progress cleared.');
      } },
  ]);
}

/* --- Theme ---------------------------------------------------------------
   The stylesheet already supports both a system-driven theme and an explicit
   override; this cycles between them. "auto" removes the attribute and lets
   prefers-color-scheme decide. */

const THEMES = ['auto', 'light', 'dark'];

function applyTheme(t) {
  if (t === 'auto') document.documentElement.removeAttribute('data-theme');
  else document.documentElement.setAttribute('data-theme', t);
  const b = $('theme-btn');
  if (b) b.textContent = t === 'auto' ? 'Theme: auto' : (t === 'dark' ? 'Theme: dark' : 'Theme: light');
}

function initTheme() {
  let t = 'auto';
  try { t = localStorage.getItem('juliagym-theme') || 'auto'; } catch (_) {}
  if (!THEMES.includes(t)) t = 'auto';
  applyTheme(t);
}

function cycleTheme() {
  let cur = document.documentElement.getAttribute('data-theme') || 'auto';
  const next = THEMES[(THEMES.indexOf(cur) + 1) % THEMES.length];
  applyTheme(next);
  try { localStorage.setItem('juliagym-theme', next); } catch (_) {}
}

let toastTimer = null;
function toast(msg) {
  const t = $('toast');
  t.textContent = msg;
  t.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { t.hidden = true; }, 2600);
}

/* --- Navigation ---------------------------------------------------------- */

async function refreshPuzzles() {
  const r = await getJSON('/api/puzzles');
  state.puzzles = r.puzzles;
  renderRail();
  if (r.skipped && r.skipped.length) {
    toast(`${r.skipped.length} puzzle(s) failed validation — see the server log.`);
  }
  return r;
}

async function selectPuzzle(id) {
  const d = await getJSON(`/api/puzzles/${encodeURIComponent(id)}`);
  state.current = d;
  state.hintsShown = d.hints_used || 0;
  renderProblem(d);
  renderRail();
  state.editor.setValue(d.draft && d.draft.trim() ? d.draft : d.starter);
  state.editor.refresh();
  $('results').innerHTML = '<div class="empty">Write a function, then press Run.</div>';
  location.hash = id;
  state.editor.focus();
}

/* --- Boot ---------------------------------------------------------------- */

async function main() {
  state.editor = makeEditor($('editor-host'));

  $('run-btn').addEventListener('click', runSubmission);
  $('hint-btn').addEventListener('click', () => showHints().catch((e) => toast(e.message)));
  $('solution-btn').addEventListener('click', confirmSolution);
  $('reset-btn').addEventListener('click', confirmReset);
  $('theme-btn').addEventListener('click', cycleTheme);
  initTheme();
  $('panel-scrim').addEventListener('click', (e) => {
    if (e.target === $('panel-scrim')) closePanel();
  });

  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && !$('panel-scrim').hidden) { closePanel(); return; }
    if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) { e.preventDefault(); runSubmission(); }
  });

  try {
    const r = await refreshPuzzles();
    if (!r.puzzles.length) {
      $('problem').innerHTML =
        '<div class="empty">No puzzles loaded. Check the server log — a puzzle that fails validation is skipped rather than served broken.</div>';
      return;
    }
    const wanted = location.hash.slice(1);
    const start = r.puzzles.find((p) => p.id === wanted)
      || r.puzzles.find((p) => !p.solved)
      || r.puzzles[0];
    await selectPuzzle(start.id);
  } catch (e) {
    $('problem').innerHTML = `<div class="empty">Could not reach the server: ${escapeHTML(e.message)}</div>`;
  }
}

window.addEventListener('hashchange', () => {
  const id = location.hash.slice(1);
  if (id && (!state.current || state.current.id !== id)) selectPuzzle(id).catch(() => {});
});

main();
