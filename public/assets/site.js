/* The public project page.
 *
 * Reads the same data/figures.json the dashboard reads, and shows only what
 * is actually in it: the strip, the corpus counts, the figures, the result.
 * Everything else on the page is static prose.
 *
 * Nothing here needs Firebase and nothing here needs a sign-in, so the page
 * works on a venue projector with the wifi blocked. It is also the page a
 * stranger can reach, which is why it carries speaker numbers and never a
 * volunteer's name: there is no code path in this file that could print one.
 */
(() => {
  'use strict';

  const $ = (s) => document.querySelector(s);
  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  }[c]));
  const pc = (x) => `${(x * 100).toFixed(1)}%`;

  /* ------------------------------------------------------------ phrases */
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

  /* -------------------------------------------------------------- data */
  const figCard = (f) => `<div class="fig${f.wide ? ' wide' : ''}">
    <button class="shot" type="button" data-cap="${esc(f.title)} — ${esc(f.caption)}">
      <img src="data/${esc(f.file)}" alt="${esc(f.title)}" loading="lazy">
    </button>
    <div class="meta">
      <h4>${esc(f.title)}</h4>
      <p>${esc(f.caption)}</p>
    </div>
  </div>`;

  const waiting = (what) => `<div class="empty"><b>${esc(what)}</b>
    <p style="margin:0">They are exported by
    <code>pipeline/ANTARVANI_figures.ipynb</code> into
    <code>web/public/data/</code>. This page shows nothing rather than a
    placeholder until they are there.</p></div>`;

  fetch('data/figures.json', { cache: 'no-store' })
    .then((r) => (r.ok ? r.json() : null))
    .then(render)
    .catch(() => render(null));

  function render(w) {
    const figs = (w && w.figures) || [];

    /* the filmstrip, if a consenting face was exported with it */
    if (w && w.strip && w.strip.length) {
      $('#stripRail').innerHTML = w.strip.map((f, i) =>
        `<img src="data/${esc(f)}" alt="Mouth crop, frame ${i + 1}" loading="lazy">`
      ).join('');
      $('#stripWho').textContent = w.stripWho || '';
      $('#strip').hidden = false;
    }

    /* corpus counts, straight from the export */
    const cs = $('#corpusStats');
    if (cs) {
      if (w && w.corpus) {
        const c = w.corpus;
        cs.innerHTML = [
          [c.speakers, 'speakers'],
          [c.clips, 'clips recorded'],
          [c.phrases, 'phrases, each a whole utterance'],
          [`${c.minutes} min`, 'of video, no audio'],
        ].map(([n, l]) =>
          `<div class="stat"><div class="n">${esc(n)}</div><div class="l">${esc(l)}</div></div>`)
          .join('');
      } else {
        cs.innerHTML = '';
      }
    }

    const cf = $('#corpusFigs');
    if (cf) {
      const mine = figs.filter((f) => f.group === 'corpus');
      cf.innerHTML = mine.length ? mine.map(figCard).join('')
        : waiting('The corpus figures have not been exported yet');
    }

    const mf = $('#modelFigs');
    if (mf) {
      const mine = figs.filter((f) => f.group === 'model');
      mf.innerHTML = mine.length ? mine.map(figCard).join('') : '';
    }

    /* the result, said plainly whichever way it came out */
    const body = $('#resultsBody');
    if (!body) return;

    if (!w || !w.results) {
      $('#resultsHead').textContent = 'Not measured yet.';
      $('#resultsLede').textContent =
        'The corpus is collected and the pipeline runs end to end. The '
        + 'cross-validation result goes here the moment there is one, and '
        + 'until then this section stays empty on purpose.';
      body.innerHTML = waiting('No training run has been published yet');
      return;
    }

    const r = w.results;
    $('#resultsHead').textContent = r.atChance
      ? 'At chance, and reported as such.'
      : `${pc(r.top1)} on speakers the model had never met.`;

    let h = r.atChance
      ? `<div class="notice bad"><b>This run did not beat chance.</b><br>
         Top-1 is ${pc(r.top1)} against a ${pc(r.chance)} baseline. It is on
         the page because a result that is reported honestly can be fixed and
         one that is dressed up cannot.</div>`
      : `<div class="notice good"><b>${esc(r.protocol)}.</b><br>
         No test clip was predicted by a model that had met that person, which
         is the only number that says anything about a new patient.</div>`;

    h += `<div class="grid g4" style="margin-top:16px">
      <div class="stat ${r.atChance ? 'bad' : 'good'}">
        <div class="n">${pc(r.top1)}</div><div class="l">top-1, unseen speakers</div>
        ${r.top1Std ? `<div class="s">± ${pc(r.top1Std)} across ${esc(r.folds)} folds</div>` : ''}
      </div>
      <div class="stat"><div class="n">${pc(r.top3)}</div><div class="l">top-3</div></div>
      <div class="stat quiet"><div class="n">${pc(r.chance)}</div>
        <div class="l">chance</div><div class="s">1 in 20</div></div>
      ${r.personalisedBest
    ? `<div class="stat good"><div class="n">${pc(r.personalisedBest)}</div>
         <div class="l">after personalisation</div>
         <div class="s">${esc(r.personalisedShots)} of the user's own clips per phrase</div></div>`
    : `<div class="stat quiet"><div class="n">${esc(r.folds)}</div><div class="l">folds</div></div>`}
    </div>`;

    const mine = figs.filter((f) => f.group === 'results');
    if (mine.length) h += `<div class="figs" style="margin-top:20px">${mine.map(figCard).join('')}</div>`;

    body.innerHTML = h;
  }
})();
