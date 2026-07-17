// Media edit page — focal point + tag picker (PublrJS store). The whole
// media Edit view (src/views/admin/media/edit.zsx) is one local:media-edit
// island; both widgets live in it.
//
// Focal point: click on the preview stores "x,y" percentages in the readonly
// #focal_point input and positions the marker. Tag picker: chips + checkbox
// dropdown + create-new synced into one hidden "tags" input. Both keep their
// server-rendered markup and mutate it imperatively — chips are added and
// removed dynamically, so chip removal uses event delegation on the chip
// container (covers server-rendered and just-created chips alike).

import { Publr } from '/static/scripts/publr.js';

Publr.store('media-edit', () => {
    let el = null;
    const part = (name) => (el ? el.querySelector('[data-publr-part="' + name + '"]') : null);

    // ── Focal point ────────────────────────────────
    function setFocalPoint(x, y) {
        const focal = part('focal');
        if (!focal) return;
        const marker = focal.querySelector('[data-publr-part="marker"]');
        const label = focal.querySelector('[data-publr-part="label"]');
        const inputId = focal.dataset.publrInput;
        const input = inputId ? document.getElementById(inputId) : null;
        if (!marker) return;

        x = Math.max(0, Math.min(100, Math.round(x)));
        y = Math.max(0, Math.min(100, Math.round(y)));
        marker.style.left = x + '%';
        marker.style.top = y + '%';
        marker.style.display = 'block';
        if (label) {
            label.textContent = x + ', ' + y;
            label.style.display = 'block';
        }
        if (input) input.value = x + ',' + y;
    }

    function initFocalPoint() {
        const focal = part('focal');
        if (!focal) return;
        const initial = focal.dataset.publrValue;
        if (initial && initial.indexOf(',') !== -1) {
            const parts = initial.split(',');
            setFocalPoint(parseFloat(parts[0]), parseFloat(parts[1]));
        } else {
            setFocalPoint(50, 50);
        }
    }

    // ── Tag picker ─────────────────────────────────
    const tagPart = (name) => {
        const picker = el ? el.querySelector('.tag-picker') : null;
        return picker ? picker.querySelector('[data-publr-part="' + name + '"]') : null;
    };

    function syncHidden() {
        const selected = tagPart('selected');
        const hidden = tagPart('hidden');
        if (!selected || !hidden) return;
        const names = [];
        selected.querySelectorAll('.tag-picker-chip').forEach((chip) => {
            names.push(chip.dataset.tagName);
        });
        hidden.value = names.join(', ');
    }

    function addChip(name, id) {
        const selected = tagPart('selected');
        if (!selected) return;
        if (selected.querySelector('[data-tag-name="' + CSS.escape(name) + '"]')) return;

        const chip = document.createElement('span');
        chip.className = 'tag-picker-chip inline-flex items-center gap-1 rounded-full bg-muted px-2 py-0.5 text-xs text-muted-foreground';
        chip.dataset.tagName = name;
        if (id) chip.dataset.tagId = id;
        else chip.dataset.tagCustom = 'true';
        chip.textContent = name;

        const removeBtn = document.createElement('button');
        removeBtn.type = 'button';
        removeBtn.className = 'tag-picker-chip-remove inline-flex h-3.5 w-3.5 cursor-pointer items-center justify-center rounded-[calc(var(--radius)*0.6)] border-0 bg-transparent p-0 text-muted-foreground hover:bg-destructive/10 hover:text-destructive';
        removeBtn.dataset.publrPart = 'remove';
        removeBtn.setAttribute('aria-label', 'Remove tag');
        removeBtn.innerHTML = '&times;';

        chip.appendChild(removeBtn);
        selected.appendChild(chip);
    }

    function removeChip(name) {
        const selected = tagPart('selected');
        const chip = selected && selected.querySelector('[data-tag-name="' + CSS.escape(name) + '"]');
        if (chip) chip.remove();
    }

    function filterOptions() {
        const search = tagPart('search');
        const options = tagPart('options');
        const createBtn = tagPart('create');
        if (!search || !options) return;
        const query = search.value.trim().toLowerCase();
        let hasExactMatch = false;
        options.querySelectorAll('.tag-picker-option').forEach((opt) => {
            const name = opt.querySelector('input').value.toLowerCase();
            opt.style.display = query.length === 0 || name.indexOf(query) !== -1 ? '' : 'none';
            if (name === query) hasExactMatch = true;
        });

        if (!createBtn) return;
        if (query.length > 0 && !hasExactMatch) {
            createBtn.textContent = 'Create tag: ' + search.value.trim();
            createBtn.style.display = '';
        } else {
            createBtn.style.display = 'none';
        }
    }

    function closeDropdown() {
        const dropdown = tagPart('dropdown');
        if (dropdown) dropdown.style.display = 'none';
    }

    const actions = {
        setFocal: (d, ctx) => {
            const focal = ctx.el;
            const img = focal.querySelector('[data-publr-part="image"]');
            if (!img) return;
            const rect = img.getBoundingClientRect();
            const x = ((ctx.event.clientX - rect.left) / rect.width) * 100;
            const y = ((ctx.event.clientY - rect.top) / rect.height) * 100;
            setFocalPoint(x, y);
        },

        tagSearchFocus: () => {
            const dropdown = tagPart('dropdown');
            if (dropdown) dropdown.style.display = '';
            filterOptions();
        },
        tagSearchInput: () => filterOptions(),
        tagCreateFromSearch: () => {
            // Enter in the search box (prevented so the form doesn't submit):
            // create only when the create row is offered.
            const createBtn = tagPart('create');
            if (createBtn && createBtn.style.display !== 'none') actions.tagCreate();
        },
        tagCloseDropdown: (d, ctx) => {
            closeDropdown();
            ctx.event.target.blur();
        },
        tagOptionToggle: (d, ctx) => {
            const cb = ctx.event.target;
            if (cb.checked) addChip(cb.value, cb.dataset.tagId);
            else removeChip(cb.value);
            syncHidden();
        },
        tagCreate: () => {
            const search = tagPart('search');
            const createBtn = tagPart('create');
            if (!search) return;
            const name = search.value.trim();
            if (name.length === 0) return;
            addChip(name, null);
            search.value = '';
            if (createBtn) createBtn.style.display = 'none';
            filterOptions();
            syncHidden();
        },
    };

    return {
        actions,
        setup: ({ el: root }) => {
            el = root;
            initFocalPoint();

            // Chip removal — delegated so dynamically created chips need no
            // per-chip listeners.
            const selected = tagPart('selected');
            const onChipClick = (e) => {
                const btn = e.target.closest('[data-publr-part="remove"]');
                if (!btn) return;
                const chip = btn.closest('.tag-picker-chip');
                if (!chip) return;
                const name = chip.dataset.tagName;
                chip.remove();
                const options = tagPart('options');
                const cb = options && options.querySelector('input[value="' + CSS.escape(name) + '"]');
                if (cb) cb.checked = false;
                syncHidden();
            };
            if (selected) selected.addEventListener('click', onChipClick);

            // Close the dropdown when a click lands outside the picker.
            const onDocClick = (e) => {
                const picker = el && el.querySelector('.tag-picker');
                if (picker && !picker.contains(e.target)) closeDropdown();
            };
            document.addEventListener('click', onDocClick);

            return () => {
                if (selected) selected.removeEventListener('click', onChipClick);
                document.removeEventListener('click', onDocClick);
                el = null;
            };
        },
    };
});
