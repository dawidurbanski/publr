// Dashboard interactivity demo — reactive data-p-* store.
// Registered with the POC reactive runtime (publr-interactivity.js), which
// coexists with CMS's register/widget runtime (interact/core.js). Drives the
// "demo" store the dashboard's `@store="demo"` island binds to.
import { Publr } from "/static/publr-interactivity.js";

const { state } = Publr.store("demo", {
  state: { shown: false },
  actions: {
    toggle: () => {
      state.shown = !state.shown;
    },
  },
});

// Smoke test for the full PublrJS runtime: @model (two-way), @for (keyed list),
// :text, and the predicate DSL (:showIf="$n == 3"). Verifies the full directive
// surface transpiles in CMS ZSX and runs. Remove once real migrations land.
const { state: smoke } = Publr.store("smoke", {
  state: { draft: "", items: [], n: 0 },
  actions: {
    add: () => {
      if (smoke.draft) {
        smoke.items.push(smoke.draft);
        smoke.draft = "";
      }
    },
    bump: () => {
      smoke.n += 1;
    },
  },
});
