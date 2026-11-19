/* Light or dark, remembered per browser.
 *
 * The page opens light. Dark is something the reader asks for, and once
 * asked for it sticks — including on the dashboard, which is a different
 * page sharing the same key.
 *
 * Applying the theme is NOT done here. It happens in a two-line inline
 * script in the <head> of each page, before the first paint, because a
 * deferred file would let a light page flash up for a frame before turning
 * dark. This file only wires the button, which can wait.
 */
(() => {
  'use strict';

  const KEY = 'antarvani-theme';
  const root = document.documentElement;

  const set = (mode) => {
    root.dataset.theme = mode;
    try { localStorage.setItem(KEY, mode); } catch (_) { /* private window */ }
    document.querySelectorAll('.theme').forEach((b) => {
      b.setAttribute('aria-pressed', String(mode === 'dark'));
      b.title = mode === 'dark' ? 'Switch to light' : 'Switch to dark';
    });
  };

  document.querySelectorAll('.theme').forEach((b) => {
    b.addEventListener('click', () =>
      set(root.dataset.theme === 'dark' ? 'light' : 'dark'));
  });

  set(root.dataset.theme === 'dark' ? 'dark' : 'light');
})();
