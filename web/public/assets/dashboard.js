/* ANTARVANI team dashboard — the live corpus and the training results.
 *
 * Two sources, kept apart on purpose:
 *
 *   Firestore        what the Android app wrote: speakers, clips, roles.
 *                    Nothing is cached or copied here, so if a number is
 *                    wrong on this page it is wrong on the collector's phone.
 *   data/figures.json what the Colab notebook exported: the corpus summary,
 *                    the figures, and the cross-validation result. Absent
 *                    until the notebook has been run, and the page says so
 *                    rather than showing a placeholder number.
 *
 * Access follows the same rule as the app. `users/{email}` holds the role;
 * the master admin is recognised by address alone, so the project can never
 * lock its own owner out.
 *
 * Volunteer names appear on this page and nowhere else. There is no export
 * button anywhere in this file, and that is deliberate: the names are
 * private project data and the only way they are meant to be read is by a
 * signed-in team member looking at this screen.
 */
import { initializeApp } from 'https://www.gstatic.com/firebasejs/10.14.1/firebase-app.js';
import {
  getAuth, GoogleAuthProvider, signInWithPopup, signOut, onAuthStateChanged,
} from 'https://www.gstatic.com/firebasejs/10.14.1/firebase-auth.js';
import {
  getFirestore, collection, doc, getDoc, getDocs,
} from 'https://www.gstatic.com/firebasejs/10.14.1/firebase-firestore.js';

window.__dashReady = true;

const MASTER = 'khurramrashid0786@gmail.com';
const PHRASES = 20;
const PIDS = Array.from({ length: PHRASES },
  (_, i) => `P${String(i + 1).padStart(2, '0')}`);

/* ----------------------------------------------------------- small tools */
const $ = (s) => document.querySelector(s);
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({
  '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
}[c]));
const pc = (x) => `${(x * 100).toFixed(1)}%`;
const plural = (n, one, many) => `${n} ${n === 1 ? one : many}`;

const view = (name) => $(`#v-${name}`);
const set = (name, html) => { const v = view(name); if (v) v.innerHTML = html; };

const head = (title, sub) =>
  `<div class="view-h"><h2>${esc(title)}</h2>${
    sub ? `<p>${sub}</p>` : ''}</div>`;

const empty = (title, body) =>
  `<div class="empty"><b>${esc(title)}</b>${body}</div>`;

/* Two delegated handlers, bound once on the document rather than on the
   rows: the speakers table is rebuilt on every keystroke in its search box,
   so a listener attached per button would pile up a fresh copy each time. */
document.addEventListener('click', (e) => {
  const open = e.target.closest('.clips-btn');
  if (open) {
    const tr = open.closest('tr');
    const already = open.getAttribute('aria-expanded') === 'true';
    const body = tr.parentNode;
    body.querySelectorAll('tr.clips-row').forEach((r) => r.remove());
    body.querySelectorAll('.clips-btn')
      .forEach((x) => x.setAttribute('aria-expanded', 'false'));
    if (already) return;           // a second click closes it
    open.setAttribute('aria-expanded', 'true');
    const row = document.createElement('tr');
    row.className = 'clips-row';
    row.innerHTML = `<td colspan="9">${clipPanel(open.dataset.sp)}</td>`;
    tr.after(row);
    return;
  }

  const play = e.target.closest('.play');
  if (play) playClip(play.dataset.fid, play.dataset.cap);
});

/* Drive's own preview player. The clip is streamed from the corpus folder,
   so Drive applies its sharing rules: a team member with access sees the
   recording, anyone else sees Drive's refusal. Nothing is copied out. */
function playClip(fileId, caption) {
  const box = $('#vbox');
  if (!box) return;
  $('#vframe').src = `https://drive.google.com/file/d/${encodeURIComponent(fileId)}/preview`;
  $('#vcap').textContent = caption || '';
  $('#vopen').href = `https://drive.google.com/file/d/${encodeURIComponent(fileId)}/view`;
  box.hidden = false;
  $('#vclose')?.focus();
}

function closeClip() {
  const box = $('#vbox');
  if (!box || box.hidden) return;
  box.hidden = true;
  $('#vframe').src = 'about:blank';   // stop playback, don't just hide it
}

document.addEventListener('click', (e) => {
  if (e.target === $('#vbox')) closeClip();
  if (e.target.closest('#vclose')) closeClip();
});
document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape') closeClip();
});

/* ================================================================= boot */
const cfg = window.FIREBASE_CONFIG;
const keyless = !cfg || !cfg.apiKey || String(cfg.apiKey).startsWith('REPLACE');

if (keyless) {
  $('#gateNote').innerHTML = '<div class="notice bad">'
    + '<b>This copy has no Firebase keys yet, so sign-in cannot start.</b><br>'
    + 'In the project folder run:<br>'
    + '<code>flutterfire configure --project=antarvaani-the-voice '
    + '--platforms=android,web</code><br><code>dart run tool/setup.dart</code>'
    + '<br><code>firebase deploy --only hosting</code><br><br>'
    + 'That writes <code>assets/firebase-config.js</code> from the same '
    + 'configuration the Android app uses.</div>';
  $('#signIn').disabled = true;
}

const app = keyless ? null : initializeApp(cfg);
const auth = app ? getAuth(app) : null;
const db = app ? getFirestore(app) : null;

$('#signIn').addEventListener('click', async () => {
  try {
    const p = new GoogleAuthProvider();
    p.setCustomParameters({ prompt: 'select_account' });
    await signInWithPopup(auth, p);
  } catch (e) {
    const why = e.code === 'auth/popup-blocked'
      ? 'The browser blocked the sign-in window. Allow pop-ups for this site and try again.'
      : e.code === 'auth/unauthorized-domain'
        ? 'This domain is not in the Firebase Authentication allow-list. Add it under Authentication → Settings → Authorized domains.'
        : esc(e.code || e.message);
    $('#gateNote').innerHTML = `<div class="notice bad"><b>Sign-in did not finish.</b><br>${why}</div>`;
  }
});

// Signing out lands on the project page, not on the sign-in wall: somebody
// who has just left the dashboard is done with it, and leaving them staring
// at the door they walked out of reads as a failed sign-out.
$('#signOut')?.addEventListener('click', async () => {
  try { await signOut(auth); } catch (_) { /* leaving anyway */ }
  location.href = 'index.html';
});
$('#refresh')?.addEventListener('click', () => { if (window.__me) load(); });

if (auth) {
  onAuthStateChanged(auth, async (user) => {
    if (!user) {
      $('#gate').hidden = false;
      $('#app').hidden = true;
      return;
    }
    const email = (user.email || '').toLowerCase();
    let role = email === MASTER ? 'master' : null;
    if (!role) {
      try {
        const snap = await getDoc(doc(db, 'users', email));
        role = snap.exists() ? (snap.data().role || null) : null;
      } catch (_) { role = null; }   // the rules said no, which is an answer
    }

    if (!role || role === 'patient') {
      $('#gateNote').innerHTML = '<div class="notice">'
        + `<b>Signed in as ${esc(email)}, but this account is not on the team yet.</b><br>`
        + 'Ask the master admin to add you in the app: Corpus → Team → Add '
        + 'member, then reload this page.</div>';
      $('#signIn').textContent = 'Use a different account';
      return;
    }

    window.__me = { email, role, name: user.displayName, photo: user.photoURL };
    $('#gate').hidden = true;
    $('#app').hidden = false;
    $('#userName').textContent = user.displayName || email;
    $('#userRole').textContent = role;
    if (user.photoURL) $('#avatar').src = user.photoURL;
    window.ANTARVANI_CHROME?.fromHash();
    load();
  });
}

/* ================================================================= load */
const DATA = { speakers: [], clips: [], users: [], signups: [], web: null, ok: false };

async function load() {
  set('overview', '<div class="grid g4">'
    + '<div class="skeleton" style="height:92px"></div>'.repeat(4)
    + '</div><div class="skeleton" style="height:190px;margin-top:16px"></div>');

  // figures.json is a plain file on the same host, so it is fetched
  // alongside Firestore rather than after it.
  const [fire, web] = await Promise.all([readFirestore(), readWeb()]);
  DATA.web = web;

  if (fire.error) {
    const msg = fire.error;
    const bad = `<div class="notice bad"><b>Could not read the corpus.</b><br>${esc(msg)}<br><br>`
      + 'If this says <code>permission-denied</code>, the account is signed '
      + 'in but <code>firestore.rules</code> does not count it as a member '
      + 'yet.</div>';
    set('overview', head('Overview') + bad);
    DATA.ok = false;
  } else {
    Object.assign(DATA, fire, { ok: true });
  }

  renderAll();
}

async function readFirestore() {
  try {
    const [sp, cl] = await Promise.all([
      getDocs(collection(db, 'speakers')),
      getDocs(collection(db, 'clips')),
    ]);
    const speakers = [];
    const clips = [];
    sp.forEach((d) => speakers.push({ id: d.id, ...d.data() }));
    cl.forEach((d) => clips.push({ id: d.id, ...d.data() }));

    // The team list is master/admin-only in the rules, so a refusal here is
    // expected for a plain member and must not fail the whole page.
    let users = [];
    try {
      const us = await getDocs(collection(db, 'users'));
      us.forEach((d) => users.push({ email: d.id, ...d.data() }));
    } catch (_) { users = []; }

    // Volunteer registrations from the public form. Admin-only in the
    // rules, so a plain member's refusal here is expected and must not
    // bring the whole page down with it.
    let signups = [];
    try {
      const sg = await getDocs(collection(db, 'signups'));
      sg.forEach((d) => signups.push({ id: d.id, ...d.data() }));
      signups.sort((a, b) =>
        String(b.createdUtc || '').localeCompare(String(a.createdUtc || '')));
    } catch (_) { signups = []; }

    return { speakers, clips, users, signups };
  } catch (e) {
    return { error: e.code || e.message };
  }
}

async function readWeb() {
  try {
    const r = await fetch('data/figures.json', { cache: 'no-store' });
    if (!r.ok) return null;
    return await r.json();
  } catch (_) { return null; }
}

/* ============================================================ derived */
function derive() {
  const { speakers, clips } = DATA;
  const rejected = new Set(
    speakers.filter((s) => s.status === 'rejected').map((s) => s.id));
  const active = speakers.filter((s) => !rejected.has(s.id));
  const live = clips.filter(
    (c) => (c.status || 'ok') === 'ok' && !rejected.has(c.speakerId));

  const bySpeaker = new Map();
  live.forEach((c) => {
    if (!bySpeaker.has(c.speakerId)) bySpeaker.set(c.speakerId, []);
    bySpeaker.get(c.speakerId).push(c);
  });

  // Mirrors SpeakerView.targetClips in dashboard_screen.dart exactly: the
  // tier decides, A is 1 take per phrase and B is 10. The stored
  // `targetClips` field is deliberately NOT trusted — older speaker rows
  // carry 40 from a since-fixed bug, and the app ignores the field too, so
  // reading it here made the website disagree with the phone about which
  // sessions were finished.
  const takes = (s) => (String(s.tier).toUpperCase() === 'B' ? 10 : 1);
  const target = (s) => PHRASES * takes(s);
  const liveOf = (id) => bySpeaker.get(id) || [];
  const complete = active.filter((s) => liveOf(s.id).length >= target(s));
  const incomplete = active.filter((s) => liveOf(s.id).length < target(s));

  return {
    rejected,
    active,
    live,
    bySpeaker,
    target,
    liveOf,
    complete,
    incomplete,
    lost: clips.filter((c) => c.status === 'lost').length,
    thrown: clips.filter((c) => c.status === 'rejected').length,
    waiting: live.filter((c) => !c.uploaded).length,
  };
}

function renderAll() {
  const d = DATA.ok ? derive() : null;
  if (d) {
    $('#rsSpeakers').textContent = d.active.length;
    $('#rsClips').textContent = d.live.length;
    $('#rsDone').textContent = `${d.complete.length}/${d.active.length}`;
    $('#rsStamp').textContent = `Read at ${new Date().toLocaleTimeString(
      undefined, { hour: '2-digit', minute: '2-digit' })}`;
    $('#cSpeakers').textContent = d.active.length;
  }
  const nSign = DATA.signups.length;
  const cS = $('#cSignups');
  if (cS) cS.textContent = nSign || '';
  const nFigs = DATA.web?.figures?.length || 0;
  $('#cFigures').textContent = nFigs || '';
  $('#cResults').textContent = DATA.web?.results ? '1' : '';

  if (d) {
    overview(d);
    speakers(d);
    collectors(d);
    breakdown(d);
    team(d);
  }
  results();
  figures();
  phrases();
  signups();
}

/* ============================================================= overview */
function overview(d) {
  const w = DATA.web;
  let h = '';

  /* The hero: the model's actual input, when the notebook has exported it.
     Nothing else on this page is allowed to be this loud. */
  if (w?.strip?.length) {
    const imgs = w.strip.map((f, i) =>
      `<img src="data/${esc(f)}" alt="Mouth crop, frame ${i + 1}" loading="lazy">`
    ).join('');
    h += `<div class="strip-wrap"><div class="strip">${imgs}</div>
      <div class="strip-cap">
        <span class="ph">${esc(window.PHRASES?.[0]?.[1] || '')}</span>
        <span class="tr">${esc(window.PHRASES?.[0]?.[3] || '')} — 48 frames of
          88×88 greyscale over three seconds, which is the model's entire
          input</span>
        <span class="mt">${esc(w.stripWho || '')}</span>
      </div></div>`;
  }

  const tiles = [
    [d.active.length, 'speakers counting', 'signal'],
    [d.live.length, 'usable clips', 'signal'],
    [`${d.complete.length}/${d.active.length}`, 'sessions complete', d.complete.length ? 'good' : 'quiet'],
    [d.waiting, d.waiting ? 'clips still to upload' : 'nothing waiting', d.waiting ? 'warn' : 'quiet'],
  ];
  h += `<div class="grid g4" style="margin-top:${w?.strip?.length ? '16px' : '0'}">`
    + tiles.map(([n, l, k]) =>
      `<div class="stat ${k}"><div class="n">${esc(n)}</div><div class="l">${esc(l)}</div></div>`)
      .join('') + '</div>';

  const flags = [];
  if (d.rejected.size) {
    flags.push(`<div class="notice"><b>${plural(d.rejected.size, 'rejected session', 'rejected sessions')}</b>
      left out of every number above: ${esc(
      DATA.speakers.filter((s) => d.rejected.has(s.id)).map((s) => s.id).join(', '))}.</div>`);
  }
  if (d.lost || d.thrown) {
    flags.push(`<div class="notice warn">${
      d.lost ? `<b>${plural(d.lost, 'clip', 'clips')} lost</b> — recorded but gone from the phone. ` : ''}${
      d.thrown ? `<b>${plural(d.thrown, 'clip', 'clips')} thrown out</b> in quality control. ` : ''}
      Lost and thrown out are counted apart: a reinstall is not a judgement
      on the recording.</div>`);
  }
  if (flags.length) h += `<div style="margin-top:16px">${flags.join('')}</div>`;

  /* coverage heat grid */
  const order = [...d.active].sort((a, b) => a.id.localeCompare(b.id));
  h += `<div class="panel" style="margin-top:20px">
    <h3>Who recorded what</h3>
    <p>One square per speaker and phrase. Gaps are the sessions still to finish.</p>
    <div class="cov" style="grid-template-columns:repeat(${PHRASES},minmax(9px,15px));margin-top:14px">`;
  order.forEach((s) => {
    const mine = d.liveOf(s.id);
    PIDS.forEach((p) => {
      const n = mine.filter((c) => c.phraseId === p).length;
      h += `<i class="${n >= 3 ? 'c' : n === 2 ? 'b' : n === 1 ? 'a' : ''}" title="${
        esc(s.id)} · ${p} · ${plural(n, 'take', 'takes')}"></i>`;
    });
  });
  h += `</div><div class="legend">
      <span><i style="background:var(--line-2)"></i>none</span>
      <span><i style="background:color-mix(in srgb,var(--signal) 38%,transparent)"></i>1 take</span>
      <span><i style="background:color-mix(in srgb,var(--signal) 68%,transparent)"></i>2</span>
      <span><i style="background:var(--signal)"></i>3 or more</span>
      <span style="margin-left:auto">${order.length} speakers × ${PHRASES} phrases</span>
    </div></div>`;

  /* the Colab headline, repeated here so Overview answers "where are we" */
  if (w?.results) {
    const r = w.results;
    h += `<div class="panel" style="margin-top:16px"><h3>Latest training run</h3>
      <p>${esc(r.protocol)}. ${r.atChance
    ? 'This run did not beat chance, and is shown as it is.'
    : 'Held-out speakers only — no test clip was predicted by a model that had met that person.'}</p>
      <div class="grid g4" style="margin-top:14px">
        <div class="stat ${r.atChance ? 'bad' : 'good'}"><div class="n">${pc(r.top1)}</div><div class="l">top-1</div></div>
        <div class="stat quiet"><div class="n">${pc(r.top3)}</div><div class="l">top-3</div></div>
        <div class="stat quiet"><div class="n">${pc(r.chance)}</div><div class="l">chance</div></div>
        <div class="stat quiet"><div class="n">${esc(r.folds)}</div><div class="l">folds</div></div>
      </div>
      <p style="margin:14px 0 0"><a href="#results" data-view="results">See the full results</a></p>
    </div>`;
  }

  set('overview', head('Overview',
    `Live from Firestore, same numbers as the app. ${
      w ? `Figures exported ${esc((w.generatedUtc || '').replace('T', ' ').replace('Z', ' UTC'))}.`
        : 'The Colab figures have not been exported yet.'}`) + h);
}

/* ============================================================= speakers */
const SF = { q: '', incomplete: false, rejected: false };

/* Every clip of a speaker, including the lost and the thrown-out ones: this
   list is for looking at recordings, and the ones that went wrong are
   exactly the ones somebody wants to see. */
function clipsOf(speakerId) {
  return DATA.clips
    .filter((c) => c.speakerId === speakerId)
    .sort((a, b) => String(a.phraseId).localeCompare(String(b.phraseId))
      || (a.take || 1) - (b.take || 1));
}

const phraseText = (pid) => {
  const row = (window.PHRASES || []).find((p) => p[0] === pid);
  return row ? { hi: row[1], en: row[3] } : { hi: '', en: '' };
};

/* The clip panel that opens under a speaker's row. Drive is the only copy of
   a recording; nothing is mirrored anywhere, so a clip is played from Drive
   and Drive decides whether the viewer may see it. Somebody signed in to
   this dashboard but not given access to the corpus folder gets Drive's own
   refusal rather than a broken frame. */
function clipPanel(speakerId) {
  const mine = clipsOf(speakerId);
  const cells = mine.map((c) => {
    const p = phraseText(c.phraseId);
    const state = c.status === 'lost' ? 'lost'
      : c.status === 'rejected' ? 'thrown out'
        : c.uploaded ? '' : 'not uploaded';
    const cls = c.status === 'lost' || c.status === 'rejected' ? 'bad'
      : c.uploaded ? 'ok' : 'warn';
    const canPlay = !!c.driveFileId;
    return `<div class="clip ${cls}">
      <div class="cid">${esc(c.phraseId)}${
      (c.take || 1) > 1 ? ` · take ${esc(c.take)}` : ''}</div>
      <div class="chi deva">${esc(p.hi)}</div>
      <div class="cen">${esc(p.en)}</div>
      ${state ? `<div class="cst">${esc(state)}</div>` : ''}
      ${canPlay
      ? `<button class="btn btn-sm play" data-fid="${esc(c.driveFileId)}"
           data-cap="${esc(speakerId)} · ${esc(c.phraseId)} · ${esc(p.en)}">
           <svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M8 5v14l11-7z"/></svg>
           Play</button>`
      : '<span class="cno">no file in Drive</span>'}
    </div>`;
  }).join('');

  const missing = PIDS.filter((p) => !mine.some((c) => c.phraseId === p));
  return `<div class="clips-panel">
    <div class="clips-head">${plural(mine.length, 'recording', 'recordings')}
      for ${esc(speakerId)}${missing.length
    ? ` · still to record: ${esc(missing.join(', '))}` : ' · all twenty phrases present'}</div>
    <div class="clip-grid">${cells}</div>
  </div>`;
}

function speakers(d) {
  // The Rejected chip SWAPS the list rather than adding to it, exactly as
  // _SpeakersTab does on the phone: rejected sessions are kept out of this
  // list the same way they are kept out of the totals, and the chip is how
  // you go and look at them.
  const rejectedRows = DATA.speakers.filter((s) => d.rejected.has(s.id))
    .sort((a, b) => a.id.localeCompare(b.id));
  const base = SF.rejected
    ? rejectedRows
    : [...d.active].sort((a, b) => a.id.localeCompare(b.id));

  const q = SF.q.toLowerCase();
  const shown = base.filter((s) => {
    if (SF.incomplete && !d.rejected.has(s.id)
      && d.liveOf(s.id).length >= d.target(s)) return false;
    if (!q) return true;
    return [s.id, s.name, s.consentFormId, s.formNo, s.accessCode,
      s.operator, s.collectorName, s.tier]
      .some((v) => String(v ?? '').toLowerCase().includes(q));
  });

  const rows = shown.map((s) => {
    const n = d.liveOf(s.id).length;
    const t = d.target(s);
    const rej = d.rejected.has(s.id);
    const ph = new Set(d.liveOf(s.id).map((c) => c.phraseId)).size;
    const cls = rej ? 'r-bad' : n >= t ? 'r-ok' : n === 0 ? 'r-none' : 'r-warn';
    const tag = rej ? '<span class="tag bad">rejected</span>'
      : n >= t ? '<span class="tag ok">complete</span>'
        : n === 0 ? '<span class="tag">empty</span>'
          : `<span class="tag warn">${t - n} left</span>`;
    const mine = clipsOf(s.id);
    return `<tr class="${cls}">
      <td><b>${esc(s.id)}</b></td>
      <td>${esc(s.name || '—')}</td>
      <td>${esc(s.consentFormId || s.formNo || '—')}</td>
      <td>${esc(s.tier || '—')}</td>
      <td class="num">${rej ? '—' : `${n}/${t}`}</td>
      <td class="num">${rej ? '—' : `${ph}/${PHRASES}`}</td>
      <td>${tag}</td>
      <td>${esc(s.operator || s.collectorName || '—')}</td>
      <td>${mine.length
      ? `<button class="btn btn-sm clips-btn" data-sp="${esc(s.id)}"
           aria-expanded="false">Clips (${mine.length})</button>`
      : '<span style="color:var(--ink-3);font-size:.82rem">none</span>'}</td>
    </tr>`;
  }).join('');

  set('speakers', head('Speakers',
    'Names are visible because you are signed in. They are never in an '
    + 'export, never on the public page, and never in the manifest the '
    + 'models are trained from.')
    + `<div class="filters">
      <label class="search">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/></svg>
        <input id="spQ" type="search" placeholder="Name, S014, F014, access code or collector"
          value="${esc(SF.q)}" aria-label="Search speakers">
      </label>
      <button class="chip" id="spInc" aria-pressed="${SF.incomplete}">Unfinished only (${d.incomplete.length})</button>
      ${d.rejected.size ? `<button class="chip" id="spRej" aria-pressed="${SF.rejected}">Rejected (${d.rejected.size})</button>` : ''}
      <span class="shown">${shown.length} of ${base.length} shown${
      SF.rejected ? ', rejected only' : ''}</span>
    </div>`
    + (shown.length ? `<div class="tbl-wrap"><table>
        <thead><tr><th>ID</th><th>Name</th><th>Form</th><th>Tier</th>
        <th class="num">Clips</th><th class="num">Phrases</th><th>Status</th>
        <th>Collected by</th><th>Recordings</th></tr></thead>
        <tbody>${rows}</tbody></table></div>`
      : empty('Nothing matches those filters',
        '<p style="margin:0">Clear the search, or switch off a chip.</p>')));

  $('#spQ')?.addEventListener('input', (e) => {
    SF.q = e.target.value.trim();
    const pos = e.target.selectionStart;
    speakers(d);
    const n = $('#spQ');
    n.focus();
    n.setSelectionRange(pos, pos);
  });
  $('#spInc')?.addEventListener('click', () => {
    SF.incomplete = !SF.incomplete; speakers(d);
  });
  $('#spRej')?.addEventListener('click', () => {
    SF.rejected = !SF.rejected; speakers(d);
  });
}

/* =========================================================== collectors */
function collectors(d) {
  const by = new Map();
  d.live.forEach((c) => {
    const k = c.collectorName || c.collectorEmail || 'unknown';
    if (!by.has(k)) by.set(k, { clips: 0, speakers: new Set() });
    const e = by.get(k);
    e.clips += 1;
    e.speakers.add(c.speakerId);
  });

  if (!by.size) {
    set('collectors', head('Collectors') + empty('No clips recorded yet',
      '<p style="margin:0">Once the app uploads its first clip, the person who recorded it appears here.</p>'));
    return;
  }

  const rank = [...by.entries()].sort((a, b) => b[1].clips - a[1].clips);
  const most = rank[0][1].clips;

  set('collectors', head('Collectors',
    'Who recorded what, counted from the clips themselves rather than from a tally anyone keeps by hand.')
    + '<div class="panel">'
    + rank.map(([k, e]) => `<div style="display:grid;grid-template-columns:minmax(120px,1.4fr) 2fr auto auto;gap:14px;align-items:center;padding:9px 0;border-bottom:1px solid var(--line-2)">
        <span style="font-weight:500">${esc(k)}</span>
        <div class="bar"><i style="width:${(100 * e.clips / most).toFixed(1)}%"></i></div>
        <span class="num" style="color:var(--ink-3);font-size:.82rem">${plural(e.speakers.size, 'speaker', 'speakers')}</span>
        <span class="num" style="font-weight:600;min-width:3.5ch">${e.clips}</span>
      </div>`).join('')
    + `<p style="margin:14px 0 0;color:var(--ink-3);font-size:.83rem">
        ${d.live.length} usable clips across ${plural(by.size, 'collector', 'collectors')}.</p></div>`);
}

/* ============================================================ breakdown */
const BF = { q: '', thin: false };

function breakdown(d) {
  const counts = PIDS.map((p) => {
    const mine = d.live.filter((c) => c.phraseId === p);
    return {
      p,
      clips: mine.length,
      speakers: new Set(mine.map((c) => c.speakerId)).size,
      meta: (window.PHRASES || []).find((x) => x[0] === p) || [p, '', '', ''],
    };
  });
  const most = Math.max(1, ...counts.map((c) => c.clips));
  const median = [...counts].sort((a, b) => a.clips - b.clips)[Math.floor(counts.length / 2)].clips;

  const q = BF.q.toLowerCase();
  const shown = counts.filter((c) => {
    if (BF.thin && c.clips >= median) return false;
    if (!q) return true;
    return [c.p, c.meta[1], c.meta[2], c.meta[3]]
      .some((v) => String(v ?? '').toLowerCase().includes(q));
  });

  set('breakdown', head('Phrase breakdown',
    `How evenly the twenty phrases are covered. An uneven corpus teaches the
     model that some phrases are simply more likely, which flatters every
     accuracy number. Median is ${median} clips per phrase.`)
    + `<div class="filters">
      <label class="search">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/></svg>
        <input id="bdQ" type="search" placeholder="P07, pankha, fan…" value="${esc(BF.q)}" aria-label="Search phrases">
      </label>
      <button class="chip" id="bdThin" aria-pressed="${BF.thin}">Below median only</button>
      <span class="shown">${shown.length} of ${PHRASES} shown</span>
    </div>`
    + (shown.length ? `<div class="tbl-wrap"><table>
      <thead><tr><th>ID</th><th>Phrase</th><th>Meaning</th>
        <th style="width:26%">Coverage</th>
        <th class="num">Clips</th><th class="num">Speakers</th></tr></thead>
      <tbody>${shown.map((c) => `<tr class="${
      c.clips >= median ? 'r-ok' : c.clips ? 'r-warn' : 'r-none'}">
        <td><b>${esc(c.p)}</b></td>
        <td class="deva" style="font-size:1.02rem">${esc(c.meta[1])}</td>
        <td style="color:var(--ink-2)">${esc(c.meta[3])}</td>
        <td><div class="bar"><i class="${c.clips < median ? 'warn' : ''}" style="width:${(100 * c.clips / most).toFixed(1)}%"></i></div></td>
        <td class="num"><b>${c.clips}</b></td>
        <td class="num">${c.speakers}</td>
      </tr>`).join('')}</tbody></table></div>`
      : empty('Nothing matches', '<p style="margin:0">Clear the search or the chip.</p>')));

  $('#bdQ')?.addEventListener('input', (e) => {
    BF.q = e.target.value.trim();
    const pos = e.target.selectionStart;
    breakdown(d);
    const n = $('#bdQ'); n.focus(); n.setSelectionRange(pos, pos);
  });
  $('#bdThin')?.addEventListener('click', () => { BF.thin = !BF.thin; breakdown(d); });
}

/* ============================================================== results */
/* Written for somebody who has not read the paper. The numbers are exactly
   the ones the notebook produced; only the words around them are plain.
   "top-1" means nothing to a visitor, and a dashboard that has to be
   explained out loud is a dashboard that failed. */
function results() {
  const w = DATA.web;

  if (!w) {
    set('results', head('How well it works') + empty(
      'No results yet',
      `<p>The numbers appear here once the figures notebook has been run.
       Run <code>pipeline/ANTARVANI_figures.ipynb</code>, download
       <code>antarvani_web_data.zip</code> from its last section, and unzip
       it into <code>web/public/data/</code> so that folder holds
       <code>figures.json</code> next to the PNGs. Then deploy again.</p>
       <p style="margin:0">Until then this page shows nothing rather than a
       made-up number.</p>`));
    return;
  }

  if (!w.results) {
    set('results', head('How well it works',
      'The recordings have been gathered, but the model has not been trained '
      + 'on them yet.')
      + empty('Not tested yet',
        `<p style="margin:0">Run <code>ANTARVANI_train.ipynb</code> to the end,
         then re-run the figures notebook and deploy again.</p>`));
    return;
  }

  const r = w.results;
  const lift = r.chance > 0 ? r.top1 / r.chance : 0;
  const inHundred = Math.round(r.top1 * 100);
  const inHundred3 = Math.round(r.top3 * 100);

  let h = '';

  h += r.atChance
    ? `<div class="notice bad"><b>It is not working yet.</b><br>
       The app picks the right phrase about ${inHundred} times in every 100,
       which is what you would get by guessing at random. The number is shown
       as it came out, because a result reported honestly can be fixed and one
       that is dressed up cannot.</div>`
    : `<div class="notice good"><b>The app picks the right phrase about
       ${inHundred} times in every 100.</b><br>
       Guessing at random would get it right about ${Math.round(r.chance * 100)}
       times in 100, so it is roughly ${lift.toFixed(1)} times better than
       guessing — and that is measured on people it had never seen before.</div>`;

  h += `<div class="grid g4" style="margin-top:16px">
    <div class="stat ${r.atChance ? 'bad' : 'good'}">
      <div class="n">${pc(r.top1)}</div>
      <div class="l">right on the first guess</div>
      <div class="s">about ${inHundred} out of every 100 phrases</div>
    </div>
    <div class="stat signal">
      <div class="n">${pc(r.top3)}</div>
      <div class="l">right within its top three guesses</div>
      <div class="s">about ${inHundred3} out of every 100</div>
    </div>
    <div class="stat quiet">
      <div class="n">${pc(r.chance)}</div>
      <div class="l">what random guessing would give</div>
      <div class="s">1 in ${PHRASES}, because there are ${PHRASES} phrases</div>
    </div>
    <div class="stat ${r.atChance ? 'bad' : 'signal'}">
      <div class="n">${lift.toFixed(1)}&times;</div>
      <div class="l">better than guessing</div>
      <div class="s">the headline number, in one figure</div>
    </div>
  </div>`;

  h += `<div class="panel" style="margin-top:16px">
    <h3>How this was measured</h3>
    <p>We split the volunteers into ${esc(r.folds)} groups. Each time, the app
      was trained on most of the groups and then tested on the people in the
      group it had never seen. That is the hard version of the test, and the
      only one that says anything about a new patient: a system tested on
      people it already knows will always look better than it is.</p>
    ${r.top1Std ? `<p style="margin:0">It does not do equally well on
      everybody. Depending on which people were held out, the score moved by
      about ${pc(r.top1Std)} either side of the average. Some faces are much
      easier to read than others, which is the gap the personalisation step
      is meant to close.</p>` : ''}
  </div>`;

  if (r.personalisedBest) {
    const gain = Math.max(0, r.personalisedBest - r.top1);
    h += `<div class="panel" style="margin-top:16px">
      <h3>What a few of your own recordings are worth</h3>
      <p>If the person using the app records
        ${plural(r.personalisedShots, 'example', 'examples')} of each phrase
        themselves, the app learns their particular way of making those shapes.
        This is the part of the project we are putting forward as new.</p>
      <div class="grid g3" style="margin-top:14px">
        <div class="stat quiet"><div class="n">${pc(r.top1)}</div>
          <div class="l">before</div>
          <div class="s">a model that has never met you</div></div>
        <div class="stat good"><div class="n">${pc(r.personalisedBest)}</div>
          <div class="l">after</div>
          <div class="s">with ${plural(r.personalisedShots, 'recording', 'recordings')} of your own per phrase</div></div>
        <div class="stat signal"><div class="n">+${pc(gain)}</div>
          <div class="l">gained</div>
          <div class="s">what those few recordings bought</div></div>
      </div></div>`;
  } else {
    h += `<div class="notice" style="margin-top:16px">
      <b>The personalisation step has not been measured yet.</b><br>
      It needs several recordings of the same phrase from the same person,
      and everyone recorded so far gave one of each. That measurement is the
      next piece of collection work.</div>`;
  }

  if (w.corpus) {
    const c = w.corpus;
    h += `<div class="panel" style="margin-top:16px">
      <h3>What it learned from</h3>
      <div class="grid g4" style="margin-top:14px">
        <div class="stat quiet"><div class="n">${esc(c.speakers)}</div><div class="l">people recorded</div></div>
        <div class="stat quiet"><div class="n">${esc(c.clips)}</div><div class="l">recordings</div></div>
        <div class="stat quiet"><div class="n">${esc(c.phrases)}</div><div class="l">phrases</div></div>
        <div class="stat quiet"><div class="n">${esc(c.minutes)}</div><div class="l">minutes of video</div></div>
      </div>
      <p style="margin:14px 0 0;color:var(--ink-3);font-size:.84rem">
        Forty-one people is a small number for this kind of task, and it is
        the main reason the score moves as much as it does.</p>
    </div>`;
  }

  const rf = (w.figures || []).filter((f) => f.group === 'results');
  if (rf.length) {
    h += `<h3 style="margin:26px 0 6px">The charts behind these numbers</h3>
      <p style="color:var(--ink-2);font-size:.89rem;margin:0 0 14px">
        Click any chart to see it full size.</p>
      <div class="figs">${rf.map(figCard).join('')}</div>`;
  }

  set('results', head('How well it works',
    `Measured on people the app had never seen. Last updated ${
      esc((w.generatedUtc || '').replace('T', ' ').replace('Z', ' UTC'))}.`) + h);
}

/* ============================================================== figures */
const GF = { q: '', group: 'all', wide: false };

function figCard(f) {
  return `<div class="fig${f.wide ? ' wide' : ''}">
    <button class="shot" type="button" data-cap="${esc(f.title)} — ${esc(f.caption)}">
      <img src="data/${esc(f.file)}" alt="${esc(f.title)}" loading="lazy">
    </button>
    <div class="meta">
      <span class="grp">${esc(f.group)}</span>
      <h4>${esc(f.title)}</h4>
      <p>${esc(f.caption)}</p>
    </div>
  </div>`;
}

function figures() {
  const all = DATA.web?.figures || [];

  if (!all.length) {
    set('figures', head('Figures') + empty('No figures exported yet',
      `<p style="margin:0">They come from
       <code>pipeline/ANTARVANI_figures.ipynb</code>. Unzip its
       <code>antarvani_web_data.zip</code> into
       <code>web/public/data/</code> and deploy again.</p>`));
    return;
  }

  const groups = ['all', ...new Set(all.map((f) => f.group))];
  const q = GF.q.toLowerCase();
  const shown = all.filter((f) => {
    if (GF.group !== 'all' && f.group !== GF.group) return false;
    if (GF.wide && !f.wide) return false;
    if (!q) return true;
    return `${f.title} ${f.caption} ${f.file} ${f.group}`.toLowerCase().includes(q);
  });

  set('figures', head('Figures',
    'Every figure the notebook produced, at full resolution. Click one to '
    + 'open it large — the same PNGs go into the synopsis and the slides.')
    + `<div class="filters">
      <label class="search">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/></svg>
        <input id="gfQ" type="search" placeholder="confusion, coverage, architecture…" value="${esc(GF.q)}" aria-label="Search figures">
      </label>
      <select class="sel" id="gfGroup" aria-label="Filter by group">
        ${groups.map((g) => `<option value="${esc(g)}"${g === GF.group ? ' selected' : ''}>${
      g === 'all' ? `All groups (${all.length})` : `${g} (${all.filter((f) => f.group === g).length})`}</option>`).join('')}
      </select>
      <button class="chip" id="gfWide" aria-pressed="${GF.wide}">Full-width only</button>
      <span class="shown">${shown.length} of ${all.length} shown</span>
    </div>`
    + (shown.length ? `<div class="figs">${shown.map(figCard).join('')}</div>`
      : empty('Nothing matches those filters',
        '<p style="margin:0">Clear the search, or pick All groups.</p>')));

  $('#gfQ')?.addEventListener('input', (e) => {
    GF.q = e.target.value.trim();
    const pos = e.target.selectionStart;
    figures();
    const n = $('#gfQ'); n.focus(); n.setSelectionRange(pos, pos);
  });
  $('#gfGroup')?.addEventListener('change', (e) => { GF.group = e.target.value; figures(); });
  $('#gfWide')?.addEventListener('click', () => { GF.wide = !GF.wide; figures(); });
}

/* ============================================================== phrases */
function phrases() {
  const list = window.PHRASES || [];
  const d = DATA.ok ? derive() : null;

  set('phrases', head('The twenty phrases',
    'Fixed, and chosen for a hospital bed rather than for a demo. The '
    + 'pipeline is the authority on this list; this page only displays it.')
    + `<div class="tbl-wrap"><table>
      <thead><tr><th>ID</th><th>Hindi</th><th>Transliteration</th>
        <th>English</th>${d ? '<th class="num">Clips</th>' : ''}</tr></thead>
      <tbody>${list.map(([p, hi, tr, en]) => {
      const n = d ? d.live.filter((c) => c.phraseId === p).length : 0;
      return `<tr><td><b>${esc(p)}</b></td>
        <td class="deva" style="font-size:1.08rem">${esc(hi)}</td>
        <td style="color:var(--ink-2)">${esc(tr)}</td>
        <td>${esc(en)}</td>${d ? `<td class="num">${n}</td>` : ''}</tr>`;
    }).join('')}</tbody></table></div>`);
}

/* ================================================================= team */
function team() {
  const me = window.__me;
  const users = DATA.users || [];

  if (!users.length) {
    set('team', head('Team access') + `<div class="notice">
      <b>The team list is not readable with this account.</b><br>
      <code>firestore.rules</code> allows it for an admin or the master
      admin. You are signed in as ${esc(me?.role || '—')}.</div>`);
    return;
  }

  const order = { master: 0, admin: 1, member: 2, patient: 3 };
  const rows = [...users]
    .sort((a, b) => (order[a.role] ?? 9) - (order[b.role] ?? 9)
      || a.email.localeCompare(b.email))
    .map((u) => {
      const isMaster = u.email.toLowerCase() === MASTER;
      const role = isMaster ? 'master' : (u.role || '—');
      return `<tr class="${role === 'master' ? 'r-ok' : role === 'admin' ? 'r-warn' : 'r-none'}">
        <td><b>${esc(u.email)}</b>${u.email.toLowerCase() === me?.email ? ' <span class="tag">you</span>' : ''}</td>
        <td>${esc(u.name || '—')}</td>
        <td><span class="tag ${role === 'master' ? 'ok' : role === 'admin' ? 'warn' : ''}">${esc(role)}</span></td>
        <td>${esc(u.addedBy || '—')}</td>
      </tr>`;
    }).join('');

  set('team', head('Team access',
    'Roles are read from Firestore and changed only in the app, by the '
    + 'master admin. This page shows them; it cannot alter them.')
    + `<div class="tbl-wrap"><table>
      <thead><tr><th>Account</th><th>Name</th><th>Role</th><th>Added by</th></tr></thead>
      <tbody>${rows}</tbody></table></div>
    <div class="notice info" style="margin-top:16px">
      <b>Only the master admin can add or remove people.</b><br>
      That is ${esc(MASTER)}, hard-coded in both the app and this page so
      the project cannot lock its own owner out.</div>`);
}


/* ============================================================== signups */
function signups() {
  const rows = DATA.signups;
  const me = window.__me;

  if (!rows.length) {
    set('signups', head('Volunteer signups',
      'People who filled in the form on the public project page.')
      + (me && (me.role === 'admin' || me.role === 'master')
        ? empty('Nobody has signed up yet',
          `<p style="margin:0">The form is at the bottom of the
           <a href="index.html#volunteer">project page</a>. Registrations
           appear here as they come in.</p>`)
        : `<div class="notice"><b>Signups are visible to administrators.</b><br>
           You are signed in as ${esc(me?.role || '\u2014')}. Ask the master
           admin if you need access.</div>`));
    return;
  }

  const body = rows.map((r) => `<tr class="r-ok">
    <td><b>${esc(r.name || '\u2014')}</b></td>
    <td><a href="tel:${esc(String(r.mobile || '').replace(/[^+\d]/g, ''))}">${esc(r.mobile || '\u2014')}</a></td>
    <td>${r.email ? `<a href="mailto:${esc(r.email)}">${esc(r.email)}</a>` : '\u2014'}</td>
    <td>${esc(r.address || '\u2014')}</td>
    <td>${esc(r.languages || '\u2014')}</td>
    <td>${esc(r.availability || '\u2014')}</td>
    <td class="num">${esc(String(r.createdUtc || '').slice(0, 10))}</td>
  </tr>`).join('');

  set('signups', head('Volunteer signups',
    `${plural(rows.length, 'person has', 'people have')} offered to be
     recorded. These are contact details people gave us in confidence: they
     are not in any export, and they do not appear anywhere on the public
     site.`)
    + `<div class="tbl-wrap"><table>
        <thead><tr><th>Name</th><th>Mobile</th><th>Email</th><th>Where</th>
        <th>Languages</th><th>Free when</th><th class="num">Signed up</th></tr></thead>
        <tbody>${body}</tbody></table></div>
      <div class="notice" style="margin-top:16px">
        <b>Before recording anyone from this list:</b> meet them, explain the
        project, and have them sign the numbered consent form. The form is
        what the consent rests on \u2014 this list is only how you reach them.
      </div>`);
}
