// Repeater field — add/remove/reorder rows (PublrJS store). Each repeater
// field (src/views/components/fields/repeater.zsx) is one local:repeater
// island; nested repeaters are nested islands, and each row's buttons resolve
// to the NEAREST island, so a nested repeater's controls never touch the
// outer one.
//
// Rows stay server-rendered (schema-driven nested field HTML — a reactive
// @for model would need a client renderer per field type; see #155). The
// store ports the legacy cloning/renumbering machinery verbatim and owns the
// lifecycle glue the legacy runtime never had: cloned rows are populated,
// then Publr.hydrate()'d (nested islands, data-p-* sub-fields) + publr:init'd
// (the "subtree re-initialized" signal other stores listen for), and rows
// are Publr.destroy()'d before permanent removal.
//
// The add/up/down/remove buttons dispatch through ONE delegated click
// listener on the island root (like the legacy widget) rather than per-button
// data-p-on: per-button wiring would park a cleanup closure in the island's
// scope for every row ever hydrated — removed rows would keep their buttons
// retained until the whole repeater unmounts.
//
// Contracts preserved (entry-editor.js / presence.js depend on them):
//   * `{field}.{index}.{subfield}` input names, renumbered contiguously —
//     including placeholders inside nested <template>s
//   * [data-repeater-count] hidden input
//   * bubbling `change` on structural edits (NOT on remote applies)
//   * publr:repeater-sync (bubbling, {field, items}) after local edits and
//     publr:repeater-apply ({items}) to rebuild from a remote peer

import { Publr } from '/static/scripts/publr.js';

Publr.store('repeater', () => {
    let el = null;
    let items = null;
    let template = null;
    let countInput = null;
    let addBtn = null;
    let max = Infinity;

    const getItems = () => items.querySelectorAll(':scope > .field-repeater-item');

    function updateState(isRemoteSync) {
        const n = getItems().length;
        countInput.value = n;
        addBtn.disabled = n >= max;

        const allItems = getItems();
        allItems.forEach((item, i) => {
            const controls = item.querySelector(':scope > .field-repeater-item-controls');
            if (!controls) return;
            const up = controls.querySelector('[data-repeater-up]');
            const down = controls.querySelector('[data-repeater-down]');
            const remove = controls.querySelector('[data-repeater-remove]');
            if (up) up.disabled = i === 0;
            if (down) down.disabled = i === allItems.length - 1;
            // Remove is never blocked: `min` (data-min) is a schema hint, not
            // an editing floor — you can always empty the repeater. Server-
            // side validation is where a real minimum would belong.
            if (remove) remove.disabled = false;
        });

        if (!isRemoteSync) {
            el.dispatchEvent(new Event('change', { bubbles: true }));
        }
    }

    // Replace __INDEX__ scoped to this repeater's field name. Only replaces
    // __INDEX__ that appears as this repeater's index component, leaving
    // nested repeater __INDEX__ placeholders intact. Recurses into nested
    // <template> content.
    function replaceFieldIndex(root, index) {
        const fieldName = el.dataset.field;
        processNode(root, fieldName + '.__INDEX__', fieldName + '.' + index);
    }

    function processNode(root, pattern, replacement) {
        root.querySelectorAll('[name]').forEach((input) => {
            if (input.name.indexOf(pattern) === 0) {
                input.name = replacement + input.name.substring(pattern.length);
            }
        });
        root.querySelectorAll('[data-field]').forEach((node) => {
            if (node.dataset.field.indexOf(pattern) === 0) {
                node.dataset.field = replacement + node.dataset.field.substring(pattern.length);
            }
        });
        root.querySelectorAll('template').forEach((tmpl) => {
            processNode(tmpl.content, pattern, replacement);
        });
    }

    // Renumber all items to contiguous 0-based indices. Only replaces the
    // first numeric index after this repeater's field prefix.
    function renumber() {
        const prefix = el.dataset.field + '.';
        getItems().forEach((item, i) => {
            renumberNode(item, prefix, i);
            item.querySelectorAll('template').forEach((tmpl) => {
                renumberNode(tmpl.content, prefix, i);
            });
        });
    }

    function renumberNode(root, prefix, newIndex) {
        root.querySelectorAll('[name]').forEach((input) => {
            input.name = replaceFirstIndex(input.name, prefix, newIndex);
        });
        root.querySelectorAll('[data-field]').forEach((node) => {
            node.dataset.field = replaceFirstIndex(node.dataset.field, prefix, newIndex);
        });
    }

    function replaceFirstIndex(str, prefix, newIndex) {
        if (str.indexOf(prefix) !== 0) return str;
        const rest = str.substring(prefix.length);
        const dotPos = rest.indexOf('.');
        const idxPart = dotPos === -1 ? rest : rest.substring(0, dotPos);
        if (!/^\d+$/.test(idxPart)) return str;
        const suffix = dotPos === -1 ? '' : rest.substring(dotPos);
        return prefix + newIndex + suffix;
    }

    // Serialize all item values as a JSON-able array for broadcasting.
    function serializeItems() {
        const prefix = el.dataset.field + '.';
        const result = [];
        const allItems = getItems();
        for (let i = 0; i < allItems.length; i++) {
            const itemPrefix = prefix + i + '.';
            const item = {};
            allItems[i].querySelectorAll('[name]').forEach((input) => {
                if (input.name.indexOf(itemPrefix) !== 0) return;
                const subField = input.name.substring(itemPrefix.length);
                if (subField.indexOf('.') !== -1) return; // skip nested
                item[subField] = input.type === 'checkbox' ? (input.checked ? 'true' : 'false') : (input.value || '');
            });
            result.push(item);
        }
        return result;
    }

    function buildClone(index) {
        const clone = template.content.cloneNode(true);
        replaceFieldIndex(clone, index);
        return clone;
    }

    // A cloned row is inert markup: hydrate instantiates nested islands
    // (nested repeaters, DS fields) and wires data-p-* sub-fields; the
    // bubbling publr:init announces the re-initialized subtree to listening
    // stores (media-library re-syncs on it; group collapse is native
    // <details> and needs nothing). Append AFTER populating — nested stores
    // must initialize from the real values, not the blank template's.
    function appendRow(clone) {
        items.appendChild(clone);
        const row = items.lastElementChild;
        if (row) {
            Publr.hydrate(row);
            row.dispatchEvent(new CustomEvent('publr:init', { bubbles: true }));
        }
        return row;
    }

    // Rebuild from received item data (remote sync).
    function applySync(data) {
        // Rows can hold islands — tear them down deterministically before
        // dropping the DOM (the unmount observer would also catch this, but
        // a microtask later).
        Publr.destroy(items);
        while (items.firstChild) items.removeChild(items.firstChild);
        for (let i = 0; i < data.length; i++) {
            const clone = buildClone(i);
            const itemPrefix = el.dataset.field + '.' + i + '.';
            for (const key in data[i]) {
                const input = clone.querySelector('[name="' + itemPrefix + key + '"]');
                if (input) {
                    if (input.type === 'checkbox') input.checked = data[i][key] === 'true';
                    else input.value = data[i][key];
                }
            }
            appendRow(clone);
        }
        updateState(true);
    }

    function dispatchSync() {
        el.dispatchEvent(new CustomEvent('publr:repeater-sync', {
            bubbles: true,
            detail: { field: el.dataset.field, items: serializeItems() },
        }));
    }

    // Delegated to the island root; the closest() check keeps a nested
    // repeater's buttons from bubbling into this one (same guard as legacy,
    // keyed on the stable .field-repeater class).
    function onClick(e) {
        const btn = e.target.closest('[data-repeater-add], [data-repeater-remove], [data-repeater-up], [data-repeater-down]');
        if (!btn || btn.closest('.field-repeater') !== el) return;

        if (btn.hasAttribute('data-repeater-add')) {
            if (getItems().length >= max) return;
            appendRow(buildClone(getItems().length));
            updateState();
            dispatchSync();
        } else if (btn.hasAttribute('data-repeater-remove')) {
            const item = btn.closest('.field-repeater-item');
            if (!item) return;
            Publr.destroy(item);
            item.remove();
            renumber();
            updateState();
            dispatchSync();
        } else if (btn.hasAttribute('data-repeater-up')) {
            const item = btn.closest('.field-repeater-item');
            if (!item || !item.previousElementSibling) return;
            items.insertBefore(item, item.previousElementSibling);
            renumber();
            updateState();
            dispatchSync();
        } else if (btn.hasAttribute('data-repeater-down')) {
            const item = btn.closest('.field-repeater-item');
            if (!item || !item.nextElementSibling) return;
            items.insertBefore(item.nextElementSibling, item);
            renumber();
            updateState();
            dispatchSync();
        }
    }

    return {
        setup: ({ el: root }) => {
            el = root;
            items = root.querySelector(':scope > .field-repeater-items');
            template = root.querySelector(':scope > template[data-repeater-template]');
            countInput = root.querySelector(':scope > [data-repeater-count]');
            addBtn = root.querySelector(':scope > [data-repeater-add]');
            if (!items || !template || !countInput || !addBtn) return undefined;

            max = root.dataset.max ? parseInt(root.dataset.max) : Infinity;

            const onApply = (e) => {
                if (!e.detail || !Array.isArray(e.detail.items)) return;
                applySync(e.detail.items);
            };
            root.addEventListener('publr:repeater-apply', onApply);
            root.addEventListener('click', onClick);

            // Init must NOT dispatch the bubbling change: nested repeaters
            // hydrate (and run this) inside a remote applySync — the change
            // would mark the form dirty and schedule an autosave echo of
            // state another user just wrote. Local edits dispatch their own
            // change from the acting repeater's updateState().
            updateState(true);

            return () => {
                root.removeEventListener('publr:repeater-apply', onApply);
                root.removeEventListener('click', onClick);
                el = null;
                items = null;
                template = null;
                countInput = null;
                addBtn = null;
            };
        },
    };
});
