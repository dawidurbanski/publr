// Content list — row selection + bulk-actions bar (PublrJS store).
// The list wrapper in views/admin/content/list.zsx is one local:content-list
// island: a bubbling onChange on the root tracks the DS Checkboxes (their own
// nested local:checkbox stores stay untouched), reactive $anySelected drives
// the bulk bar's hidden wrapper, and the count text updates imperatively
// (the DS BulkActions count has no reactive slot yet).
//
// The bulk item buttons (Duplicate / Add to release / Delete) are server-side
// placeholders — no content.bulk* actions exist yet — so only selection state
// is wired here, matching the legacy behavior.

import { Publr } from '/static/scripts/publr.js';

Publr.store('content-list', () => {
    const state = Publr.reactive({ anySelected: false });

    let el = null;
    const rows = () => (el ? [...el.querySelectorAll('input[name="select-entry"]')] : []);

    function sync() {
        if (!el) return;
        const boxes = rows();
        const selected = boxes.filter((cb) => cb.checked).length;
        state.anySelected = selected > 0;

        const countEl = el.querySelector('[data-publr-part="count"]');
        if (countEl && countEl.firstChild) countEl.firstChild.nodeValue = selected + ' ';

        const master = el.querySelector('input[name="select-all"]');
        if (master) {
            master.checked = selected > 0 && selected === boxes.length;
            master.indeterminate = selected > 0 && selected < boxes.length;
        }
    }

    return {
        state,
        actions: {
            selectionChanged: (d, ctx) => {
                const target = ctx.event.target;
                if (target.name === 'select-all') {
                    rows().forEach((cb) => { cb.checked = target.checked; });
                    sync();
                } else if (target.name === 'select-entry') {
                    sync();
                }
            },
            clearSelection: () => {
                rows().forEach((cb) => { cb.checked = false; });
                sync();
            },
        },
        setup: ({ el: root }) => {
            el = root;
            const onInit = () => sync();
            root.addEventListener('publr:init', onInit);
            sync();
            return () => {
                root.removeEventListener('publr:init', onInit);
                el = null;
            };
        },
    };
});
