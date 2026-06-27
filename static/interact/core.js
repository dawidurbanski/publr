// Publr Interactivity — Core
// The single, idempotent runtime for all client interactivity. Safe to
// re-run after an HMR innerHTML swap: re-wires freshly swapped-in nodes
// without double-binding or leaking document/window listeners.
//
// Three ways to wire behavior — pick by SCOPE:
//
//   register(type, fn)   Per-element component. fn(el) runs ONCE per element
//                        (guarded by el._publrInit). Use for setup tied to a
//                        specific element: reading state, building structure,
//                        observers, timers. Attach only ELEMENT-scoped
//                        listeners here (they die with the element on swap and
//                        are re-attached to the new element on re-init).
//
//   widget(type, fn)     Same as register but keyed off [data-widget]
//                        (guarded by el._publrWidgetInit).
//
//   delegate(evt, sel, fn)  ONE listener on `document` per event type, bound
//                        once, dispatching to the nearest ancestor matching
//                        `sel` via closest(). Works for dynamically swapped-in
//                        elements with ZERO re-binding and ZERO leaks — the
//                        preferred way to handle clicks/changes/etc. Prefer
//                        this over element-bound listeners in register().
//
//   feature(name, fn)    One-time global setup. Runs EXACTLY ONCE (first init),
//                        never again — so any document/window listener set up
//                        here never accumulates across swaps.

const handlers = {};   // data-publr-component type -> fn(el)
const widgets = {};    // data-widget type -> fn(el)
const features = [];   // { fn, ran }  one-time global setup
const scans = [];      // fn  idempotent element scans, run every init
const delegated = {};  // eventType -> { list: [{selector, fn}] }

export function register(type, fn) {
    handlers[type] = fn;
}

export function widget(type, fn) {
    widgets[type] = fn;
}

export function feature(_name, fn) {
    features.push({ fn, ran: false });
}

// Idempotent element scan, run on EVERY init (including after each HMR swap).
// For modules that wire several elements keyed off ids/classes rather than a
// single data attribute (e.g. admin.js). The fn MUST guard its own wiring
// (per-element flag) so re-running only touches freshly swapped-in nodes —
// otherwise it would double-bind. Document/window listeners must NOT live in
// a scan fn (they'd accumulate); use delegate() or feature() for those.
export function scan(fn) {
    scans.push(fn);
}

// Delegated event handler. Binds a single document listener per event type
// (capture=false / bubble phase — fine for click, mousedown, keydown,
// input, change, submit, focusin, focusout, all of which bubble). Dispatches
// to every registered (selector, fn) whose selector matches an ancestor of
// the event target. Called at module load, so the document listener is bound
// once per page; re-init never re-binds it.
export function delegate(event, selector, fn) {
    let entry = delegated[event];
    if (!entry) {
        entry = delegated[event] = { list: [] };
        document.addEventListener(event, function (e) {
            const list = entry.list;
            for (let i = 0; i < list.length; i++) {
                const d = list[i];
                const el = e.target && e.target.closest ? e.target.closest(d.selector) : null;
                if (el) d.fn(e, el);
            }
        });
    }
    entry.list.push({ selector, fn });
}

// Idempotent. Wires not-yet-initialized component/widget elements and runs
// any not-yet-run features. Called on DOMContentLoaded and after every HMR
// swap (via window.__publrReinit).
export function init() {
    document.querySelectorAll('[data-publr-component]').forEach(el => {
        if (el._publrInit) return;
        const type = el.dataset.publrComponent;
        if (handlers[type]) {
            el._publrInit = true;
            handlers[type](el);
        }
    });
    document.querySelectorAll('[data-widget]').forEach(el => {
        if (el._publrWidgetInit) return;
        const type = el.dataset.widget;
        if (widgets[type]) {
            el._publrWidgetInit = true;
            widgets[type](el);
        }
    });
    for (let i = 0; i < features.length; i++) {
        if (!features[i].ran) {
            features[i].ran = true;
            features[i].fn();
        }
    }
    for (let i = 0; i < scans.length; i++) {
        scans[i]();
    }
}

document.addEventListener('DOMContentLoaded', init);

// Expose the idempotent entry point so the dev HMR client (a plain injected
// <script>, which can't import this module) can re-run it after a fast-path
// swap to wire the freshly swapped-in DOM.
if (typeof window !== 'undefined') {
    window.__publrReinit = init;
}
