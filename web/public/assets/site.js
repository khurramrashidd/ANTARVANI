/* The public project page.
 *
 * This page explains the project and takes volunteer registrations. It shows
 * NO project data — no corpus counts, no accuracy, no figures, no
 * recordings, and it never reads any of those collections. The only thing it
 * writes is a row in `signups`, from the form at the bottom.
 *
 * That write is the one place a stranger touches the database, so it is
 * worth saying what protects it. The form is not the protection:
 * firestore.rules is. The rules allow create on `signups` and nothing else —
 * no read, no update, no delete — and only for a row with exactly the
 * expected field names, each a short string, with both tick-boxes actually
 * ticked. A visitor cannot read back what they or anyone else submitted. The
 * checks in this file exist to give a person a useful message before they
 * hit a refusal, not to decide anything.
 */
import { initializeApp } from 'https://www.gstatic.com/firebasejs/10.14.1/firebase-app.js';
import {
  getFirestore, collection, addDoc,
} from 'https://www.gstatic.com/firebasejs/10.14.1/firebase-firestore.js';

const $ = (s) => document.querySelector(s);
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({
  '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
}[c]));

const ABSTRACT = 'data/abstract.pdf';

/* ---------------------------------------------------------------- phrases */
const grid = $('#phraseGrid');
if (grid && window.PHRASES) {
  grid.innerHTML = window.PHRASES.map(([id, hi, tr, en]) =>
    `<div class="phrase">
      <div class="id">${esc(id)}</div>
      <div class="hi">${esc(hi)}</div>
      <div class="en">${esc(en)}</div>
    </div>`).join('');
}

const built = $('#builtAt');
if (built) {
  built.textContent = new Date().toLocaleDateString(undefined,
    { year: 'numeric', month: 'long' });
}

/* --------------------------------------------------------------- abstract */
const pdfBox = $('#pdfBox');
const pdfBtn = $('#readAbstract');

function openPdf() {
  if (!pdfBox) return;
  $('#pdfFrame').src = ABSTRACT;
  pdfBox.hidden = false;
  $('#pdfClose')?.focus();
}
function closePdf() {
  if (!pdfBox || pdfBox.hidden) return;
  pdfBox.hidden = true;
  $('#pdfFrame').src = 'about:blank';
}
pdfBtn?.addEventListener('click', openPdf);
$('#pdfClose')?.addEventListener('click', closePdf);
document.addEventListener('click', (e) => { if (e.target === pdfBox) closePdf(); });
document.addEventListener('keydown', (e) => { if (e.key === 'Escape') closePdf(); });

// A button that opens an empty grey frame is worse than one that is not
// offered. The abstract is dropped in by hand, so its absence is ordinary.
fetch(ABSTRACT, { method: 'HEAD' })
  .then((r) => { if (!r.ok) throw new Error(String(r.status)); })
  .catch(() => {
    if (pdfBtn) pdfBtn.disabled = true;
    const note = $('#abstractNote');
    if (note) {
      note.innerHTML = '<div class="notice">The abstract has not been '
        + 'published yet. Put the PDF at <code>web/public/data/abstract.pdf</code> '
        + 'and deploy again, and it opens here in the page.</div>';
    }
  });

/* ------------------------------------------------------- volunteer signup */
const form = $('#volForm');
const note = $('#volNote');
const submit = $('#volSubmit');

const cfg = window.FIREBASE_CONFIG;
const keyless = !cfg || !cfg.apiKey || String(cfg.apiKey).startsWith('REPLACE');
let db = null;
if (form && !keyless) {
  try { db = getFirestore(initializeApp(cfg)); } catch (_) { db = null; }
}

const say = (cls, html) => {
  if (note) note.innerHTML = `<div class="notice ${cls}">${html}</div>`;
};

if (form && (keyless || !db)) {
  submit.disabled = true;
  say('bad', '<b>The form is not connected yet.</b><br>Run '
    + '<code>dart run tool/setup.dart</code> in the project folder and deploy '
    + 'again — it writes the Firebase keys this page needs.');
}

form?.addEventListener('submit', async (e) => {
  e.preventDefault();
  if (!db) return;

  const f = new FormData(form);
  const name = String(f.get('name') || '').trim();
  const mobile = String(f.get('mobile') || '').trim();
  const digits = mobile.replace(/\D/g, '');

  // Told before they press, not after: a form that clears itself and says
  // "error" is how people give up.
  if (name.length < 2) return say('bad', 'Please put in your name.');
  if (digits.length < 7) {
    return say('bad', 'That mobile number looks too short — we need a way to reach you.');
  }
  if (!f.get('over18')) {
    return say('bad', 'We can only record people aged 18 or over, so please '
      + 'confirm that box.');
  }
  if (!f.get('consent')) {
    return say('bad', 'Please tick the box agreeing we may contact you.');
  }

  submit.disabled = true;
  const was = submit.textContent;
  submit.textContent = 'Sending…';
  say('', 'Sending your details…');

  try {
    await addDoc(collection(db, 'signups'), {
      name,
      mobile,
      email: String(f.get('email') || '').trim(),
      address: String(f.get('address') || '').trim(),
      languages: f.getAll('lang').join(', '),
      availability: String(f.get('availability') || '').trim(),
      over18: true,
      consent: true,
      createdUtc: new Date().toISOString(),
      source: 'website',
    });
    form.reset();
    say('good', `<b>Thank you, ${esc(name.split(' ')[0])}.</b><br>`
      + 'Someone from the team will call you to arrange a time. Nothing is '
      + 'recorded until you have met us and signed the consent form.');
  } catch (err) {
    say('bad', '<b>That did not send.</b><br>'
      + esc(err.code || err.message)
      + '<br><br>You can also reach the team directly at '
      + '<a href="mailto:khurramrashid0786@gmail.com">khurramrashid0786@gmail.com</a>.');
  } finally {
    submit.disabled = false;
    submit.textContent = was;
  }
});
