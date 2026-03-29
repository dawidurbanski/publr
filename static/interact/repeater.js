// Publr Interactivity — Repeater Widget
// Add/remove/reorder items in repeater field containers.

import { widget, init } from './core.js';

widget('repeater', function(el) {
    var items = el.querySelector(':scope > .field-repeater-items');
    var template = el.querySelector(':scope > template[data-repeater-template]');
    var countInput = el.querySelector(':scope > [data-repeater-count]');
    var addBtn = el.querySelector(':scope > [data-repeater-add]');
    if (!items || !template || !countInput || !addBtn) return;

    var min = parseInt(el.dataset.min) || 0;
    var max = el.dataset.max ? parseInt(el.dataset.max) : Infinity;

    function getItems() {
        return items.querySelectorAll(':scope > .field-repeater-item');
    }

    function updateState(isRemoteSync) {
        var n = getItems().length;
        countInput.value = n;
        addBtn.disabled = n >= max;

        // Per-item button states
        var allItems = getItems();
        allItems.forEach(function(item, i) {
            var controls = item.querySelector(':scope > .field-repeater-item-controls');
            if (!controls) return;
            var up = controls.querySelector('[data-repeater-up]');
            var down = controls.querySelector('[data-repeater-down]');
            var remove = controls.querySelector('[data-repeater-remove]');
            if (up) up.disabled = i === 0;
            if (down) down.disabled = i === allItems.length - 1;
            if (remove) remove.disabled = n <= min;
        });

        if (!isRemoteSync) {
            el.dispatchEvent(new Event('change', { bubbles: true }));
        }
    }

    // Replace __INDEX__ scoped to this repeater's field name.
    // Only replaces __INDEX__ that appears as this repeater's index component,
    // leaving nested repeater __INDEX__ placeholders intact.
    // Recurses into nested <template> content.
    function replaceFieldIndex(root, index) {
        var fieldName = el.dataset.field;
        var pattern = fieldName + '.__INDEX__';
        var replacement = fieldName + '.' + index;
        processNode(root, pattern, replacement);
    }

    function processNode(root, pattern, replacement) {
        root.querySelectorAll('[name]').forEach(function(input) {
            if (input.name.indexOf(pattern) === 0) {
                input.name = replacement + input.name.substring(pattern.length);
            }
        });
        root.querySelectorAll('[data-field]').forEach(function(node) {
            if (node.dataset.field.indexOf(pattern) === 0) {
                node.dataset.field = replacement + node.dataset.field.substring(pattern.length);
            }
        });
        root.querySelectorAll('template').forEach(function(tmpl) {
            processNode(tmpl.content, pattern, replacement);
        });
    }

    // Renumber all items to contiguous 0-based indices.
    // Only replaces the first numeric index after this repeater's field prefix.
    function renumber() {
        var prefix = el.dataset.field + '.';
        getItems().forEach(function(item, i) {
            renumberNode(item, prefix, i);
            item.querySelectorAll('template').forEach(function(tmpl) {
                renumberNode(tmpl.content, prefix, i);
            });
        });
    }

    function renumberNode(root, prefix, newIndex) {
        root.querySelectorAll('[name]').forEach(function(input) {
            input.name = replaceFirstIndex(input.name, prefix, newIndex);
        });
        root.querySelectorAll('[data-field]').forEach(function(node) {
            node.dataset.field = replaceFirstIndex(node.dataset.field, prefix, newIndex);
        });
    }

    function replaceFirstIndex(str, prefix, newIndex) {
        if (str.indexOf(prefix) !== 0) return str;
        var rest = str.substring(prefix.length);
        var dotPos = rest.indexOf('.');
        var idxPart = dotPos === -1 ? rest : rest.substring(0, dotPos);
        if (!/^\d+$/.test(idxPart)) return str;
        var suffix = dotPos === -1 ? '' : rest.substring(dotPos);
        return prefix + newIndex + suffix;
    }

    // Serialize all item values as JSON array for broadcasting
    function serializeItems() {
        var fieldName = el.dataset.field;
        var prefix = fieldName + '.';
        var result = [];
        var allItems = getItems();
        for (var i = 0; i < allItems.length; i++) {
            var itemPrefix = prefix + i + '.';
            var item = {};
            allItems[i].querySelectorAll('[name]').forEach(function(input) {
                if (input.name.indexOf(itemPrefix) !== 0) return;
                var subField = input.name.substring(itemPrefix.length);
                if (subField.indexOf('.') !== -1) return; // skip nested
                item[subField] = input.type === 'checkbox' ? (input.checked ? 'true' : 'false') : (input.value || '');
            });
            result.push(item);
        }
        return result;
    }

    // Rebuild repeater from received item data (remote sync)
    function applySync(data) {
        // Clear existing items
        while (items.firstChild) items.removeChild(items.firstChild);
        // Rebuild from data
        for (var i = 0; i < data.length; i++) {
            var clone = template.content.cloneNode(true);
            replaceFieldIndex(clone, i);
            var itemPrefix = el.dataset.field + '.' + i + '.';
            for (var key in data[i]) {
                var input = clone.querySelector('[name="' + itemPrefix + key + '"]');
                if (input) {
                    if (input.type === 'checkbox') input.checked = data[i][key] === 'true';
                    else input.value = data[i][key];
                }
            }
            items.appendChild(clone);
        }
        init();
        updateState(true);
    }

    // Listen for remote sync events
    el.addEventListener('publr:repeater-apply', function(e) {
        if (!e.detail || !Array.isArray(e.detail.items)) return;
        applySync(e.detail.items);
    });

    // Dispatch sync event after structural changes
    function dispatchSync() {
        el.dispatchEvent(new CustomEvent('publr:repeater-sync', {
            bubbles: true,
            detail: { field: el.dataset.field, items: serializeItems() }
        }));
    }

    // Event delegation — scoped to this repeater via closest() check
    el.addEventListener('click', function(e) {
        var btn = e.target.closest('[data-repeater-add], [data-repeater-remove], [data-repeater-up], [data-repeater-down]');
        if (!btn || btn.closest('[data-widget="repeater"]') !== el) return;

        if (btn.hasAttribute('data-repeater-add')) {
            if (getItems().length >= max) return;
            var clone = template.content.cloneNode(true);
            replaceFieldIndex(clone, getItems().length);
            items.appendChild(clone);
            init();
            updateState();
            dispatchSync();
        } else if (btn.hasAttribute('data-repeater-remove')) {
            var item = btn.closest('.field-repeater-item');
            if (!item || getItems().length <= min) return;
            item.remove();
            renumber();
            updateState();
            dispatchSync();
        } else if (btn.hasAttribute('data-repeater-up')) {
            var item = btn.closest('.field-repeater-item');
            if (!item || !item.previousElementSibling) return;
            items.insertBefore(item, item.previousElementSibling);
            renumber();
            updateState();
            dispatchSync();
        } else if (btn.hasAttribute('data-repeater-down')) {
            var item = btn.closest('.field-repeater-item');
            if (!item || !item.nextElementSibling) return;
            items.insertBefore(item.nextElementSibling, item);
            renumber();
            updateState();
            dispatchSync();
        }
    });

    updateState();
});
