// PublrJS plugin — Focus trap (opt-in companion module, #150).
// Trap Tab/Shift+Tab within a container, save + restore previous focus.
// Components that need it (dialog) `import { trapFocus } from
// "./publr-interactivity-focus.js"`; deduped to one load per page by the module
// cache. Ported from design-system/src/js/publr-focus.js (no runtime dependency).

const FOCUSABLE =
  'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';

// Trap focus within container; returns a release() function. Focuses the first
// focusable element (or opts.initialFocus).
export function trapFocus(container, opts = {}) {
  const focusable = () => container.querySelectorAll(FOCUSABLE);
  const items = focusable();
  if (!items.length) return () => {};

  const prevFocus = document.activeElement;

  if (opts.initialFocus) {
    opts.initialFocus.focus();
  } else {
    items[0].focus();
  }

  function handler(e) {
    if (e.key !== "Tab") return;
    const els = focusable();
    if (!els.length) return;
    const first = els[0];
    const last = els[els.length - 1];

    if (e.shiftKey && document.activeElement === first) {
      e.preventDefault();
      last.focus();
    } else if (!e.shiftKey && document.activeElement === last) {
      e.preventDefault();
      first.focus();
    }
  }

  container.addEventListener("keydown", handler);

  return function release() {
    container.removeEventListener("keydown", handler);
    if (prevFocus && prevFocus.focus) prevFocus.focus();
  };
}
