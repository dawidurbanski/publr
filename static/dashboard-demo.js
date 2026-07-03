// Dashboard PublrJS demo — reactive data-p-* store.
// Registered with the POC reactive runtime (publr.js), which
// coexists with CMS's register/widget runtime (interact/core.js). Drives the
// "demo" store the dashboard's `@store="demo"` island binds to.
import { Publr } from "/static/publr.js";

const { state } = Publr.store("demo", {
  state: { shown: false },
  actions: {
    toggle: () => {
      state.shown = !state.shown;
    },
  },
});
