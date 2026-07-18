// Admin shell chrome — PublrJS migration of interact/admin-shell.js (#148).
// Sidebar drawer (mobile) + theme toggle + command palette + environment
// switcher, driven by reactive flags. The markup in layout.zsx carries the
// directives (@store="shell", :showIf, :class, @click, :aria-*).
// The pre-paint theme guard stays inline in layout.zsx's <head> (it must run
// before first paint, which a deferred module can't).
import { Publr, effect } from "/static/scripts/publr.js";

const { state: shell } = Publr.store("shell", {
  state: {
    open: false,
    commandOpen: false,
    environmentOpen: false,
    environment: "Production",
  },
  actions: {
    toggle: () => {
      shell.open = !shell.open;
    },
    // Escape / overlay click: close every shell layer.
    close: () => {
      shell.open = false;
      shell.commandOpen = false;
      shell.environmentOpen = false;
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
    openCommand: () => {
      shell.commandOpen = true;
      shell.open = false;
    },
    closeCommand: () => {
      shell.commandOpen = false;
    },
    openEnvironment: () => {
      shell.environmentOpen = true;
    },
    closeEnvironment: () => {
      shell.environmentOpen = false;
    },
    setEnvironment: (data) => {
      shell.environment = data.environment;
      shell.environmentOpen = false;
      window.publr?.toast?.(`Switched to ${data.environment}`);
    },
  },
});

// Body scroll-lock follows any full-screen layer — a side effect outside the
// island.
effect(() => {
  document.body.style.overflow =
    shell.open || shell.commandOpen || shell.environmentOpen ? "hidden" : "";
});

// Focus the palette input once it appears (its subtree toggles via :showIf).
effect(() => {
  if (!shell.commandOpen) return;
  requestAnimationFrame(() => {
    document
      .querySelector('[aria-label="Command palette"] input[type="search"]')
      ?.focus();
  });
});

// ⌘K / Ctrl-K opens the command palette from anywhere.
window.addEventListener("keydown", (ev) => {
  if ((ev.metaKey || ev.ctrlKey) && ev.key.toLowerCase() === "k") {
    ev.preventDefault();
    shell.commandOpen = !shell.commandOpen;
  }
});

// Crossing to desktop resets the mobile drawer (reactive state; class/attr/
// backdrop/scroll-lock all follow via their directives + the effect above).
window.matchMedia("(min-width: 1024px)").addEventListener("change", (ev) => {
  if (ev.matches) shell.open = false;
});
