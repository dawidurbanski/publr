// Version compare — PublrJS store (island = the compare <form> in
// views/components/version_compare.zsx). Diff-only toggle and apply-button
// enablement are reactive; "select all from this version" checks every
// enabled old-side radio.

import { Publr } from '/static/scripts/publr.js';

Publr.store('version-compare', () => {
    const state = Publr.reactive({
        diffOnly: false,
        canApply: false,
    });

    let el = null;

    function recompute() {
        state.canApply = !!(el && el.querySelector('.version-compare-cell-old input[type="radio"]:checked'));
    }

    return {
        state,
        actions: {
            toggleDiffOnly: (d, ctx) => {
                state.diffOnly = ctx.event.target.checked;
            },
            radioChanged: (d, ctx) => {
                if (ctx.event.target.type === 'radio') recompute();
            },
            selectAllOld: () => {
                if (!el) return;
                el.querySelectorAll('.version-compare-cell-old input[type="radio"]:not(:disabled)').forEach((r) => {
                    r.checked = true;
                });
                recompute();
            },
        },
        setup: ({ el: root }) => {
            el = root;
            recompute();
            return () => { el = null; };
        },
    };
});
