/* Everything around the data: the rail, the section router, the clock, the
 * weather, and the figure lightbox.
 *
 * Deliberately independent of Firebase. If sign-in breaks, or the SDK is
 * blocked by venue wifi, this file still runs — so the shell is never a
 * half-drawn page, and the clock on screen is still the right time.
 */
(() => {
  'use strict';

  const $ = (s) => document.querySelector(s);
  const $$ = (s) => Array.from(document.querySelectorAll(s));

  /* ------------------------------------------------------------- router */
  const TITLES = {
    overview: 'Overview',
    speakers: 'Speakers',
    collectors: 'Collectors',
    breakdown: 'Phrase breakdown',
    results: 'How well it works',
    figures: 'Figures',
    phrases: 'The twenty phrases',
    signups: 'Volunteer signups',
    team: 'Team access',
  };

  const show = (name) => {
    if (!TITLES[name]) name = 'overview';
    $$('.view').forEach((v) => { v.hidden = v.id !== `v-${name}`; });
    $$('#nav a[data-view]').forEach((a) => {
      if (a.dataset.view === name) a.setAttribute('aria-current', 'page');
      else a.removeAttribute('aria-current');
    });
    const t = $('#viewTitle');
    if (t) t.textContent = TITLES[name];
    closeRail();
    // Each section starts at its own top; carrying the previous section's
    // scroll position down into a short one looks like a broken page.
    window.scrollTo({ top: 0, behavior: 'instant' });
    document.dispatchEvent(new CustomEvent('view', { detail: name }));
  };

  const fromHash = () => show((location.hash || '#overview').slice(1));

  /* Only the dashboard has sections to switch between. The public page uses
     the same file for its clock and lightbox, and its #problem / #team links
     are ordinary anchors — routing them would scroll the reader back to the
     top of a page they were trying to jump down. */
  const isApp = !!document.querySelector('.view');

  if (isApp) {
    window.addEventListener('hashchange', fromHash);

    // Footer links share the same data-view contract as the rail.
    document.addEventListener('click', (e) => {
      const a = e.target.closest('a[data-view]');
      if (!a || !a.dataset.view) return;
      if (!a.getAttribute('href')?.startsWith('#')) return;
      e.preventDefault();
      if (location.hash === a.getAttribute('href')) fromHash();
      else location.hash = a.getAttribute('href');
    });
  }

  /* ------------------------------------------------------- rail drawer */
  const rail = $('#rail');
  const scrim = $('#scrim');
  const menu = $('#menuBtn');

  function openRail() {
    rail?.classList.add('open');
    if (scrim) scrim.hidden = false;
    menu?.setAttribute('aria-expanded', 'true');
  }
  function closeRail() {
    rail?.classList.remove('open');
    if (scrim) scrim.hidden = true;
    menu?.setAttribute('aria-expanded', 'false');
  }
  menu?.addEventListener('click', () => {
    rail?.classList.contains('open') ? closeRail() : openRail();
  });
  scrim?.addEventListener('click', closeRail);

  /* ------------------------------------------- the public page's drawer */
  // The project page has no rail, so its hamburger drives a slide-in panel
  // instead. Picking a section closes it, which is the behaviour people
  // expect and the easiest one to forget.
  const drawer = $('#drawer');
  const dScrim = $('#drawerScrim');
  const burger = $('#burger');

  function openDrawer() {
    drawer?.classList.add('open');
    if (dScrim) dScrim.hidden = false;
    burger?.setAttribute('aria-expanded', 'true');
    $('#drawerClose')?.focus();
  }
  function shutDrawer() {
    drawer?.classList.remove('open');
    if (dScrim) dScrim.hidden = true;
    burger?.setAttribute('aria-expanded', 'false');
  }
  burger?.addEventListener('click', () => {
    drawer?.classList.contains('open') ? shutDrawer() : openDrawer();
  });
  $('#drawerClose')?.addEventListener('click', shutDrawer);
  dScrim?.addEventListener('click', shutDrawer);
  drawer?.querySelectorAll('a').forEach((a) =>
    a.addEventListener('click', shutDrawer));

  /* -------------------------------------------------------------- clock */
  // Minutes, not seconds: a ticking seconds display on a dashboard is
  // motion that tells nobody anything. Ten seconds keeps the minute honest.
  function tick() {
    const d = new Date();
    const date = $('#clkDate');
    const time = $('#clkTime');
    if (date) {
      date.textContent = d.toLocaleDateString(undefined, {
        weekday: 'short', day: 'numeric', month: 'short',
      });
    }
    if (time) {
      time.textContent = d.toLocaleTimeString(undefined, {
        hour: '2-digit', minute: '2-digit',
      });
    }
    const y = $('#footYear');
    if (y) y.textContent = `Major Project · ${d.getFullYear()}`;
  }
  tick();
  setInterval(tick, 10000);

  /* ------------------------------------------------------------ weather */
  // Open-Meteo needs no key and no sign-up. A fixed place rather than asking
  // the browser for one: a location permission prompt on a dashboard opened
  // in front of an audience is worse than a named city. Change these three
  // values to move it.
  const PLACE = { name: 'Panvel', lat: 18.9894, lon: 73.1175 };

  // WMO code groups, each with the shape it should draw.
  const SKY = [
    [[0, 1], 'Clear', 'sun'],
    [[2], 'Part cloud', 'cloud-sun'],
    [[3], 'Cloudy', 'cloud'],
    [[45, 48], 'Fog', 'fog'],
    [[51, 53, 55, 56, 57], 'Drizzle', 'rain'],
    [[61, 63, 65, 66, 67, 80, 81, 82], 'Rain', 'rain'],
    [[71, 73, 75, 77, 85, 86], 'Snow', 'snow'],
    [[95, 96, 99], 'Storm', 'storm'],
  ];

  const PATHS = {
    sun: '<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/>',
    'cloud-sun': '<circle cx="8.5" cy="8" r="3"/><path d="M8.5 2.2v1.3M3.3 8H2M4.8 4.3 3.9 3.4M13 8h1.2"/><path d="M7 19h10a3 3 0 0 0 0-6 4.4 4.4 0 0 0-8.3-1A3.2 3.2 0 0 0 7 19z"/>',
    cloud: '<path d="M7 18h10a3.3 3.3 0 0 0 .2-6.6 5 5 0 0 0-9.5-1.2A3.4 3.4 0 0 0 7 18z"/>',
    fog: '<path d="M6 10h12M4 14h16M7 18h10"/>',
    rain: '<path d="M7 15h10a3.3 3.3 0 0 0 .2-6.6 5 5 0 0 0-9.5-1.2A3.4 3.4 0 0 0 7 15z"/><path d="M9 18.5v2M13 18.5v2.5M17 18.5v2"/>',
    snow: '<path d="M7 15h10a3.3 3.3 0 0 0 .2-6.6 5 5 0 0 0-9.5-1.2A3.4 3.4 0 0 0 7 15z"/><path d="M9 19h.01M13 20h.01M17 19h.01"/>',
    storm: '<path d="M7 14h10a3.3 3.3 0 0 0 .2-6.6 5 5 0 0 0-9.5-1.2A3.4 3.4 0 0 0 7 14z"/><path d="m13 15-2.5 4H14l-1.5 3.5"/>',
  };

  async function weather() {
    const wrap = $('#wx');
    if (!wrap) return;
    try {
      const u = 'https://api.open-meteo.com/v1/forecast'
        + `?latitude=${PLACE.lat}&longitude=${PLACE.lon}`
        + '&current=temperature_2m,weather_code&timezone=auto';
      const r = await fetch(u, { cache: 'no-store' });
      if (!r.ok) throw new Error(String(r.status));
      const j = await r.json();
      const t = Math.round(j?.current?.temperature_2m);
      const code = j?.current?.weather_code;
      if (!Number.isFinite(t)) throw new Error('no temperature');

      const hit = SKY.find(([codes]) => codes.includes(code));
      const label = hit ? hit[1] : 'Now';
      const shape = hit ? hit[2] : 'cloud';

      $('#wxTemp').textContent = `${t}°C`;
      $('#wxPlace').textContent = PLACE.name;
      const icon = $('#wxIcon');
      if (icon) icon.innerHTML = PATHS[shape] || PATHS.cloud;
      wrap.title = `${label} in ${PLACE.name}, ${t}°C`;
      wrap.classList.remove('off');
    } catch (_) {
      // No weather is not a failure worth a message. The space just stays
      // empty rather than showing a stale or guessed number.
      wrap.classList.add('off');
    }
  }
  weather();
  setInterval(weather, 15 * 60 * 1000);

  /* ----------------------------------------------------------- lightbox */
  const box = $('#box');
  const boxImg = $('#boxImg');
  const boxCap = $('#boxCap');
  let lastFocus = null;

  function openBox(src, alt, cap) {
    if (!box) return;
    lastFocus = document.activeElement;
    boxImg.src = src;
    boxImg.alt = alt || '';
    boxCap.textContent = cap || '';
    box.hidden = false;
    $('#boxX')?.focus();
  }
  function closeBox() {
    if (!box || box.hidden) return;
    box.hidden = true;
    boxImg.removeAttribute('src');
    lastFocus?.focus();
  }

  document.addEventListener('click', (e) => {
    const b = e.target.closest('button.shot');
    if (b) {
      const img = b.querySelector('img');
      openBox(img?.src, img?.alt, b.dataset.cap);
      return;
    }
    if (e.target === box) closeBox();
  });
  $('#boxX')?.addEventListener('click', closeBox);
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') { closeBox(); closeRail(); shutDrawer(); }
  });

  /* Let dashboard.js drive the router once it has signed the user in. On the
     public page fromHash is a no-op, which is what the caller wants there. */
  window.ANTARVANI_CHROME = { show: isApp ? show : () => {},
    fromHash: isApp ? fromHash : () => {} };
})();
