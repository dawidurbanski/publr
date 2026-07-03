// Admin shell chrome — PublrJS migration of interact/admin-shell.js (#148).
// Sidebar drawer (mobile) + theme toggle, driven by a single reactive `open`
// flag instead of imperative class/attr juggling. The markup in layout.zsx
// carries the directives (@store="shell", :showIf, :class, @click, :aria-*).
// The pre-paint theme guard stays inline in layout.zsx's <head> (it must run
// before first paint, which a deferred module can't).
import { Publr, effect } from "/static/publr.js";

const { state: shell } = Publr.store("shell", {
  state: { open: false },
  actions: {
    toggle: () => {
      shell.open = !shell.open;
    },
    close: () => {
      shell.open = false;
    },
    // Clicking a nav link closes the drawer on mobile (ignore non-link clicks
    // like the search box). ctx.event from the delegated @click on the sidebar.
    navClose: (_data, ctx) => {
      if (
        ctx.event.target.closest("a") &&
        window.matchMedia("(max-width: 1023px)").matches
      ) {
        shell.open = false;
      }
    },
    toggleTheme: () => {
      const dark = document.documentElement.classList.toggle("dark");
      localStorage.setItem("publr-theme", dark ? "dark" : "light");
    },
  },
});

// Body scroll-lock follows the open state — a side effect outside the island.
effect(() => {
  document.body.style.overflow = shell.open ? "hidden" : "";
});

// Crossing to desktop resets the mobile drawer (reactive state; class/attr/
// backdrop/scroll-lock all follow via their directives + the effect above).
window.matchMedia("(min-width: 1024px)").addEventListener("change", (ev) => {
  if (ev.matches) shell.open = false;
});
