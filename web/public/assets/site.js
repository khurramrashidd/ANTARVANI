/* ANTARVANI showcase.
 *
 * Everything variable on this page comes from data/figures.json, which the
 * Colab notebook writes. The page is built to be opened before that file
 * exists: every section that needs it degrades to an honest placeholder
 * rather than an empty hole or a crash, because a half-built site in front
 * of a judge is worse than a site that says what is still coming.
 */
(() => {
  'use strict';

  const $ = (s, r = document) => r.querySelector(s);
  const el = (tag, cls, html) => {
    const n = document.createElement(tag);
    if (cls) n.className = cls;
    if (html != null) n.innerHTML = html;
    return n;
  };
  const esc = (s) => String(s).replace(/[&<>"]/g,
    (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  const pct = (x) => `${(x * 100).toFixed(1)}%`;

  // ------------------------------------------------------- phrases
  const pg = $('#phraseGrid');
  if (pg) {
    (window.PHRASES || []).forEach(([id, hi, ro, en]) => {
      pg.append(el('div', 'phrase rise',
        `<div class="id">${esc(id)}</div>
         <div class="hi" lang="hi">${esc(hi)}</div>
         <div class="ro">${esc(ro)}</div>
         <div class="en">${esc(en)}</div>`));
    });
  }

  // ------------------------------------------------------ lightbox
  const lb = $('#lb'), lbImg = $('#lbImg');
  const openLb = (src, alt) => {
    lbImg.src = src;
    lbImg.alt = alt || '';
    lb.classList.add('on');
    document.body.style.overflow = 'hidden';
  };
  const closeLb = () => {
    lb.classList.remove('on');
    lbImg.src = '';
    document.body.style.overflow = '';
  };
  if (lb) {
    lb.addEventListener('click', closeLb);
    document.addEventListener('keydown', (e) => {
      if (e.key === 'Escape' && lb.classList.contains('on')) closeLb();
    });
  }

  const figure = (f) => {
    const fig = el('figure', `fig rise${f.wide ? ' wide' : ''}`);
    const btn = el('button', 'shot');
    btn.type = 'button';
    const img = el('img');
    img.src = `data/${f.file}`;
    img.alt = f.title || f.file;
    img.loading = 'lazy';
    // A figure the export did not produce leaves no broken frame behind.
    img.addEventListener('error', () => fig.remove());
    btn.append(img);
    btn.addEventListener('click', () => openLb(img.src, img.alt));
    fig.append(btn);
    if (f.title || f.caption) {
      fig.append(el('figcaption', null,
        `${f.title ? `<b>${esc(f.title)}</b>` : ''}${esc(f.caption || '')}`));
    }
    return fig;
  };

  const stat = (n, l, plain) =>
    el('div', `stat rise${plain ? ' plain' : ''}`,
      `<div class="n">${esc(n)}</div><div class="l">${esc(l)}</div>`);

  // -------------------------------------------------- scroll reveal
  const io = 'IntersectionObserver' in window
    ? new IntersectionObserver((rows) => {
        rows.forEach((r) => {
          if (r.isIntersecting) { r.target.classList.add('in'); io.unobserve(r.target); }
        });
      }, { rootMargin: '0px 0px -8% 0px' })
    : null;
  const watch = (root = document) => {
    root.querySelectorAll('.rise:not(.in)').forEach((n) => {
      if (io) io.observe(n); else n.classList.add('in');
    });
  };

  // Lazily loaded figures change the page height after the observer has
  // made its mind up, and a section can end up permanently faded out. A
  // single sweep once everything has settled costs nothing and removes
  // the whole class of failure.
  const revealAll = () =>
    document.querySelectorAll('.rise:not(.in)').forEach((n) => n.classList.add('in'));
  window.addEventListener('load', () => setTimeout(revealAll, 1200));
  setTimeout(revealAll, 4000);

  // ------------------------------------------------------ the data
  const nothingYet = (what) => el('div', 'notice',
    `${esc(what)} appear here once the figures notebook has been run. ` +
    'Open <code>pipeline/ANTARVANI_figures.ipynb</code> in Colab, Run all, ' +
    'and unzip its download into <code>web/public/data/</code>.');

  fetch('data/figures.json', { cache: 'no-store' })
    .then((r) => (r.ok ? r.json() : Promise.reject(new Error(String(r.status)))))
    .then(render)
    .catch(() => render(null))
    .finally(watch);

  function render(d) {
    const foot = $('#builtAt');
    if (foot) {
      foot.textContent = d && d.generatedUtc
        ? `Figures generated ${new Date(d.generatedUtc).toLocaleDateString(
            undefined, { day: 'numeric', month: 'long', year: 'numeric' })}`
        : '';
    }

    // ---- hero filmstrip, only when the export provided one
    if (d && Array.isArray(d.strip) && d.strip.length) {
      const rail = $('#stripRail');
      let shown = 0;
      d.strip.forEach((file) => {
        const img = el('img');
        img.src = `data/${file}`;
        img.alt = 'A single mouth crop as the model receives it';
        img.loading = 'lazy';
        img.addEventListener('error', () => img.remove());
        img.addEventListener('load', () => { if (!shown++) $('#strip').hidden = false; });
        rail.append(img);
      });
      const who = $('#stripWho');
      if (who) who.textContent = d.stripWho || '';
    }

    // ---- corpus
    const cs = $('#corpusStats');
    const c = (d && d.corpus) || null;
    if (cs) {
      if (c) {
        cs.append(stat(c.speakers, 'volunteers recorded'));
        cs.append(stat(c.clips, 'clips in the corpus'));
        cs.append(stat(c.phrases, 'phrases, every one of them'));
        cs.append(stat(`${c.minutes} min`, 'of video, no audio', true));
      } else {
        cs.replaceWith(nothingYet('Corpus figures'));
      }
    }

    const byGroup = (g) => ((d && d.figures) || []).filter((f) => f.group === g);
    const fill = (sel, group) => {
      const host = $(sel);
      if (!host) return;
      const rows = byGroup(group);
      rows.forEach((f) => host.append(figure(f)));
      return rows.length;
    };
    fill('#corpusFigs', 'corpus');
    fill('#modelFigs', 'model');

    // ---- results
    const body = $('#resultsBody');
    if (!body) return;
    const r = d && d.results;

    if (!r) {
      body.append(el('div', 'notice',
        '<b>Model training is the next stage.</b><br>' +
        'The corpus, the app and the pipeline are built and running; the ' +
        'evaluation is the work of Major Project 2. Figures appear here ' +
        'automatically from the training run — this page does not hold a ' +
        'number that an experiment has not produced.'));
      return;
    }

    const tiles = el('div', 'stats g4');
    tiles.append(stat(pct(r.top1), 'top-1, speaker never seen in training'));
    tiles.append(stat(pct(r.top3), 'top-3, speaker never seen'));
    if (r.personalisedBest != null) {
      tiles.append(stat(pct(r.personalisedBest),
        `with ${r.personalisedShots || 'a few'} of the user's own clips`));
    }
    tiles.append(stat(pct(r.chance), 'chance, for 20 phrases', true));
    body.append(tiles);

    const head = $('#resultsHead'), lede = $('#resultsLede');
    if (r.atChance) {
      // The honest version of a bad number, stated before anyone asks.
      if (head) head.textContent = 'Preliminary — the model is still at chance.';
      if (lede) {
        lede.textContent =
          'This is reported as it came out of the run. A model at chance is ' +
          'predicting the same phrase whatever it is shown, which points at ' +
          'the pipeline rather than at the size of the corpus; diagnosis is ' +
          'in progress and the figures below are the evidence.';
      }
      body.append(el('div', 'notice bad',
        '<b>Read this before the numbers below.</b> Top-1 is at or near the ' +
        '1-in-20 baseline, so the model has not learned to tell the phrases ' +
        'apart yet. The corpus, the app and the training pipeline all work ' +
        'end to end; what is shown here is a diagnosis in progress, not a ' +
        'result we are claiming.'));
    } else if (lede) {
      lede.textContent =
        `${r.protocol || 'Leave-speakers-out cross-validation'}: every test ` +
        'clip was predicted by a model that never saw that person. Standard ' +
        `deviation across folds ${(100 * (r.top1Std || 0)).toFixed(1)} points.`;
    }

    const figs = byGroup('results');
    if (figs.length) {
      const host = el('div', 'grid figs');
      host.style.marginTop = '22px';
      figs.forEach((f) => host.append(figure(f)));
      body.append(host);
    }
  }
})();
