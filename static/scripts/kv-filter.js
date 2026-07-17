// Variables list — client-side row filter (PublrJS store).
// The /admin/variables list is one local:kv-filter island; the search input's
// onInput action toggles row visibility on case-insensitive substring match
// against each row's combined text (key + label + value preview).

import { Publr } from '/static/scripts/publr.js';

Publr.store('kv-filter', () => {
    let el = null;

    return {
        actions: {
            filter: (d, ctx) => {
                const needle = (ctx.event.target.value || '').toLowerCase().trim();
                if (!el) return;
                el.querySelectorAll('[data-kv-section] tbody tr').forEach((row) => {
                    if (!needle) { row.style.display = ''; return; }
                    const text = (row.textContent || '').toLowerCase();
                    row.style.display = text.indexOf(needle) === -1 ? 'none' : '';
                });
            },
        },
        setup: ({ el: root }) => {
            el = root;
            return () => { el = null; };
        },
    };
});
