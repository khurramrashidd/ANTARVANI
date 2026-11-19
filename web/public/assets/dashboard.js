/* ANTARVANI team dashboard — the live corpus, on the web.
 *
 * Reads the same Firestore the Android app writes, so the numbers here and
 * the numbers on a collector's phone are the same numbers. Nothing is
 * cached, nothing is copied: if it is wrong here it is wrong in the app.
 *
 * Access follows the same rule as the app. `users/{email}` holds the role;
 * the master admin is recognised by address alone so the project can never
 * lock its own owner out. Anyone else signing in sees a polite wall — the
 * Firestore rules would refuse them anyway, and being told why is kinder
 * than a console full of permission errors.
 *
 * Volunteer names appear on this page and nowhere public. That is the whole
 * reason the dashboard is behind a sign-in.
 */
import { initializeApp } from 'https://www.gstatic.com/firebasejs/10.14.1/firebase-app.js';
import {
  getAuth, GoogleAuthProvider, signInWithPopup, signOut, onAuthStateChanged,
} from 'https://www.gstatic.com/firebasejs/10.14.1/firebase-auth.js';
import {
  getFirestore, collection, doc, getDoc, getDocs,
} from 'https://www.gstatic.com/firebasejs/10.14.1/firebase-firestore.js';

// Tells the fallback in dashboard.html that the SDK arrived and this
// script is running, so it does not report a network failure that is not.
window.__dashReady = true;

const MASTER = 'khurramrashid0786@gmail.com';
const PHRASES = 20;

const $ = (s) => document.querySelector(s);
const el = (t, c, h) => {
  const n = document.createElement(t);
  if (c) n.className = c;
  if (h != null) n.innerHTML = h;
  return n;
};
const esc = (s) => String(s ?? '').replace(/[&<>"]/g,
  (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

const note = (cls, html) => el('div', `notice ${cls}`, html);

// ---------------------------------------------------------------- boot
const cfg = window.FIREBASE_CONFIG;
if (!cfg || !cfg.apiKey || String(cfg.apiKey).startsWith('REPLACE')) {
  $('#gateNote').append(note('bad',
    '<b>This copy has no Firebase keys yet.</b><br>Run <code>setup</code> in ' +
    'the project folder — it writes <code>web/public/assets/firebase-config.js</code> ' +
    'from the same configuration the Android app uses, then deploy again.'));
  $('#signIn').disabled = true;
}

const app = cfg && cfg.apiKey ? initializeApp(cfg) : null;
const auth = app ? getAuth(app) : null;
const db = app ? getFirestore(app) : null;

$('#signIn').addEventListener('click', async () => {
  try {
    const provider = new GoogleAuthProvider();
    provider.setCustomParameters({ prompt: 'select_account' });
    await signInWithPopup(auth, provider);
  } catch (e) {
    $('#gateNote').replaceChildren(note('bad',
      `Sign-in did not finish: ${esc(e.code || e.message)}`));
  }
});

$('#signOut')?.addEventListener('click', () => signOut(auth));
$('#refresh')?.addEventListener('click', () => load(window.__me));

if (auth) {
  onAuthStateChanged(auth, async (user) => {
    if (!user) {
      $('#gate').hidden = false;
      $('#dash').hidden = true;
      return;
    }
    const email = (user.email || '').toLowerCase();
    let role = email === MASTER ? 'master' : null;

    if (!role) {
      try {
        const snap = await getDoc(doc(db, 'users', email));
        role = snap.exists() ? (snap.data().role || null) : null;
      } catch (_) {
        role = null;    // the rules said no, which is an answer
      }
    }

    if (!role || role === 'patient') {
      $('#gateNote').replaceChildren(note('',
        `<b>Signed in as ${esc(email)}, but this account is not on the team ` +
        'yet.</b><br>Ask the master admin to add you from the app: ' +
        'Corpus → Team → Add member. Then reload this page.'));
      $('#signIn').textContent = 'Use a different account';
      return;
    }

    window.__me = { email, role, name: user.displayName, photo: user.photoURL };
    $('#gate').hidden = true;
    $('#dash').hidden = false;
    $('#userName').textContent = user.displayName || email;
    $('#userRole').textContent = role;
    if (user.photoURL) {
      $('#avatar').src = user.photoURL;
      $('#avatar').hidden = false;
    }
    load(window.__me);
  });
}

// ---------------------------------------------------------------- data
async function load(me) {
  const body = $('#dashBody');
  body.replaceChildren(el('div', 'skeleton', ''), el('div', 'skeleton', ''));
  body.querySelectorAll('.skeleton').forEach((s) => { s.style.height = '120px'; s.style.marginBottom = '14px'; });

  let speakers = [];
  let clips = [];
  try {
    const [sp, cl] = await Promise.all([
      getDocs(collection(db, 'speakers')),
      getDocs(collection(db, 'clips')),
    ]);
    sp.forEach((d) => speakers.push({ id: d.id, ...d.data() }));
    cl.forEach((d) => clips.push({ id: d.id, ...d.data() }));
  } catch (e) {
    body.replaceChildren(note('bad',
      `<b>Could not read the corpus.</b><br>${esc(e.code || e.message)}<br><br>` +
      'If this says <code>permission-denied</code>, the account is signed in ' +
      'but not a member yet.'));
    return;
  }
  render(body, me, speakers, clips);
}

function render(body, me, speakers, clips) {
  body.replaceChildren();

  const rejected = new Set(speakers.filter((s) => s.status === 'rejected').map((s) => s.id));
  const active = speakers.filter((s) => !rejected.has(s.id));
  const live = clips.filter((c) => (c.status || 'ok') === 'ok' && !rejected.has(c.speakerId));
  const lost = clips.filter((c) => c.status === 'lost').length;
  const thrown = clips.filter((c) => c.status === 'rejected').length;
  const waiting = live.filter((c) => !c.uploaded).length;

  const target = (s) => s.targetClips || PHRASES * (s.tier === 'A' ? 2 : 10);
  const liveOf = (id) => live.filter((c) => c.speakerId === id);
  const done = active.filter((s) => liveOf(s.id).length >= target(s)).length;

  // ------------------------------------------------------------ tiles
  const tiles = el('div', 'stats g4');
  const tile = (n, l, plain) => tiles.append(el('div', `stat${plain ? ' plain' : ''}`,
    `<div class="n">${esc(n)}</div><div class="l">${esc(l)}</div>`));
  tile(active.length, 'speakers counting');
  tile(live.length, 'usable clips');
  tile(done, `sessions complete of ${active.length}`);
  tile(waiting, waiting ? 'clips still to upload' : 'nothing waiting to upload', !waiting);
  body.append(tiles);

  const flags = [];
  if (rejected.size) flags.push(`${rejected.size} rejected session${rejected.size > 1 ? 's' : ''} left out of every number above`);
  if (lost) flags.push(`${lost} clip${lost > 1 ? 's' : ''} lost`);
  if (thrown) flags.push(`${thrown} thrown out in QC`);
  if (flags.length) {
    body.append(el('div', 'notice', `${esc(flags.join(' · '))}.`));
    body.lastChild.style.marginTop = '16px';
  }

  // --------------------------------------------------------- coverage
  const ids = Array.from({ length: PHRASES }, (_, i) => `P${String(i + 1).padStart(2, '0')}`);
  const order = [...active].sort((a, b) => a.id.localeCompare(b.id));
  const cov = el('div', 'card');
  cov.style.marginTop = '26px';
  cov.append(el('h3', null, 'Who recorded what'));
  const grid = el('div', 'cov');
  grid.style.gridTemplateColumns = `repeat(${PHRASES}, 1fr)`;
  grid.style.marginTop = '14px';
  order.forEach((s) => {
    const mine = liveOf(s.id);
    ids.forEach((p) => {
      const n = mine.filter((c) => c.phraseId === p).length;
      const cell = el('i', n >= 3 ? 'c' : n === 2 ? 'b' : n === 1 ? 'a' : '');
      cell.title = `${s.id} · ${p} · ${n} take${n === 1 ? '' : 's'}`;
      grid.append(cell);
    });
  });
  cov.append(grid);
  cov.append(el('div', 'legend',
    '<span><i style="background:rgba(255,255,255,.055)"></i>none</span>' +
    '<span><i style="background:rgba(129,140,248,.45)"></i>1 take</span>' +
    '<span><i style="background:#6366f1"></i>2</span>' +
    '<span><i style="background:#a855f7"></i>3+</span>' +
    `<span style="margin-left:auto">${order.length} speakers × ${PHRASES} phrases</span>`));
  body.append(cov);

  // -------------------------------------------------------- collectors
  const byCollector = new Map();
  live.forEach((c) => {
    const k = c.collectorName || c.collectorEmail || 'unknown';
    byCollector.set(k, (byCollector.get(k) || 0) + 1);
  });
  if (byCollector.size) {
    const most = Math.max(...byCollector.values());
    const card = el('div', 'card');
    card.style.marginTop = '20px';
    card.append(el('h3', null, 'Clips by collector'));
    const rows = el('div');
    rows.style.marginTop = '12px';
    [...byCollector.entries()].sort((a, b) => b[1] - a[1]).forEach(([k, v]) => {
      const row = el('div');
      row.style.cssText = 'display:grid;grid-template-columns:minmax(110px,1fr) 2fr auto;gap:12px;align-items:center;padding:7px 0';
      row.append(el('span', null, esc(k)));
      const bar = el('div', 'bar', `<i style="width:${(100 * v / most).toFixed(1)}%"></i>`);
      row.append(bar);
      row.append(el('span', null, `<b>${v}</b>`));
      rows.append(row);
    });
    card.append(rows);
    body.append(card);
  }

  // ---------------------------------------------------------- speakers
  const wrap = el('div');
  wrap.style.marginTop = '26px';
  wrap.append(el('h3', null, 'Speakers'));
  const hint = el('p', null,
    'Names are visible because you are signed in. They are never in an ' +
    'export and never on the public page.');
  hint.style.cssText = 'color:var(--ink-3);font-size:.85rem;margin:6px 0 12px';
  wrap.append(hint);

  const tw = el('div', 'tbl-wrap');
  const rows = order.concat(speakers.filter((s) => rejected.has(s.id)))
    .map((s) => {
      const n = liveOf(s.id).length;
      const t = target(s);
      const isRej = rejected.has(s.id);
      const tag = isRej ? '<span class="tag bad">rejected</span>'
        : n >= t ? '<span class="tag ok">complete</span>'
        : n === 0 ? '<span class="tag">empty</span>'
        : `<span class="tag warn">${t - n} left</span>`;
      return `<tr>
        <td><b>${esc(s.id)}</b></td>
        <td>${esc(s.name || '—')}</td>
        <td>${esc(s.consentFormId || s.formNo || '—')}</td>
        <td>${esc(s.tier || '—')}</td>
        <td class="num">${isRej ? '—' : `${n}/${t}`}</td>
        <td>${tag}</td>
        <td>${esc(s.operator || s.collectorName || '—')}</td>
      </tr>`;
    }).join('');
  tw.append(el('table', null,
    `<thead><tr><th>ID</th><th>Name</th><th>Form</th><th>Tier</th>
      <th class="num">Clips</th><th>Status</th><th>Collected by</th></tr></thead>
     <tbody>${rows}</tbody>`));
  wrap.append(tw);
  body.append(wrap);

  const stamp = el('p', null,
    `Live from Firestore · ${new Date().toLocaleTimeString()} · signed in as ${esc(me.email)}`);
  stamp.style.cssText = 'color:var(--ink-3);font-size:.8rem;margin-top:18px';
  body.append(stamp);
}
