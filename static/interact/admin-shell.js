// Publr Interactivity — Admin shell chrome
// Sidebar toggle + theme toggle, ported off the layout's inline <script>
// IIFEs into the runtime. All event handling is delegated (one document
// listener per event, bound once at module load) and queries the sidebar
// fresh each time — so it survives HMR swaps of the layout with no leaks and
// no lost handlers. (The pre-paint theme guard stays inline in the layout: it
// must run synchronously before first paint, which a deferred module can't.)

import { delegate } from './core.js';

// ── Sidebar ────────────────────────────────────────────────────────────
// Query fresh on each use so handlers always act on the current sidebar
// (the layout — and thus these nodes — can be swapped in by HMR).

function sidebar() { return document.querySelector('[data-publr-component="admin-sidebar"]'); }
function backdrop() { return document.querySelector('[data-publr-sidebar-backdrop]'); }
function trigger() { return document.querySelector('[data-publr-sidebar-trigger]'); }

function openSidebar() {
    const s = sidebar(); if (!s) return;
    const b = backdrop(), t = trigger();
    s.classList.remove('-translate-x-full');
    s.setAttribute('data-publr-sidebar-state', 'open');
    if (b) b.classList.remove('hidden');
    if (t) t.setAttribute('aria-expanded', 'true');
    document.body.style.overflow = 'hidden';
}

function closeSidebar() {
    const s = sidebar(); if (!s) return;
    const b = backdrop(), t = trigger();
    s.classList.add('-translate-x-full');
    s.setAttribute('data-publr-sidebar-state', 'closed');
    if (b) b.classList.add('hidden');
    if (t) t.setAttribute('aria-expanded', 'false');
    document.body.style.overflow = '';
}

// Trigger button toggles; backdrop click closes; nav-link click closes on mobile.
delegate('click', '[data-publr-sidebar-trigger]', (e) => {
    e.stopPropagation();
    const s = sidebar();
    if (s && s.getAttribute('data-publr-sidebar-state') === 'open') closeSidebar();
    else openSidebar();
});
delegate('click', '[data-publr-sidebar-backdrop]', () => closeSidebar());
delegate('click', '[data-publr-component="admin-sidebar"] a', () => {
    if (window.matchMedia('(max-width: 1023px)').matches) closeSidebar();
});

// Escape closes; crossing to desktop resets. Bound ONCE at module load (the
// module loads once per page), querying the sidebar fresh — no per-swap
// rebinding, no accumulation.
document.addEventListener('keydown', (e) => {
    const s = sidebar();
    if (e.key === 'Escape' && s && s.getAttribute('data-publr-sidebar-state') === 'open') closeSidebar();
});
window.matchMedia('(min-width: 1024px)').addEventListener('change', (ev) => {
    if (!ev.matches) return;
    const s = sidebar(), b = backdrop(), t = trigger();
    if (b) b.classList.add('hidden');
    document.body.style.overflow = '';
    if (t) t.setAttribute('aria-expanded', 'false');
    if (s) s.setAttribute('data-publr-sidebar-state', 'closed');
});

// ── Theme toggle ───────────────────────────────────────────────────────
// (The pre-paint theme application stays inline in layout.zsx's <head>.)
delegate('click', '#theme-toggle', () => {
    const dark = document.documentElement.classList.toggle('dark');
    localStorage.setItem('publr-theme', dark ? 'dark' : 'light');
});
