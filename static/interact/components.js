// Publr Interactivity — Component Handlers
// Registers handlers for: toggle, dialog, dropdown, select, popover, tooltip, toast, tabs, switch.

import { register } from './core.js';
import { open, close, toggle, isOpen } from './toggle.js';
import { portal, unportal, position } from './portal.js';
import { trapFocus, releaseFocus } from './focus-trap.js';

let uid = 0;
function nextId(prefix) {
    return 'publr-' + prefix + '-' + (++uid);
}

// ── Toggle ──────────────────────────────────────
register('toggle', (el) => {
    const trigger = el.querySelector('[data-publr-part="trigger"]');
    if (!trigger) return;
    trigger.addEventListener('click', () => toggle(el));
});

// ── Dialog ──────────────────────────────────────
register('dialog', (el) => {
    const trigger = el.querySelector('[data-publr-part="trigger"]');
    const content = el.querySelector('[data-publr-part="content"]');
    const closeBtn = el.querySelector('[data-publr-part="close"]');
    if (!trigger || !content) return;

    trigger.addEventListener('click', () => {
        open(el);
        trapFocus(content);
        el._publrOnClose = () => {
            releaseFocus(content);
            trigger.focus();
        };
    });

    if (closeBtn) {
        closeBtn.addEventListener('click', () => close(el));
    }

    // Overlay click (only if dismissable)
    content.addEventListener('click', (e) => {
        if (e.target === content && el.dataset.publrDismissable !== 'false') {
            close(el);
        }
    });
});

// ── Dropdown Menu ───────────────────────────────
register('dropdown', (el) => {
    const trigger = el.querySelector('[data-publr-part="trigger"]');
    const content = el.querySelector('[data-publr-part="content"]');
    if (!trigger || !content) return;
    el._publrContent = content;

    trigger.addEventListener('click', () => {
        if (isOpen(el)) {
            close(el);
        } else {
            open(el);
            portal(content);
            position(content, trigger);
            el._publrOnClose = () => unportal(content);
            const first = content.querySelector('[data-publr-part="item"]');
            if (first) first.focus();
        }
    });

    // Keyboard navigation
    content.addEventListener('keydown', (e) => {
        const items = content.querySelectorAll('[data-publr-part="item"]');
        if (!items.length) return;
        const idx = Array.from(items).indexOf(document.activeElement);

        if (e.key === 'ArrowDown') {
            e.preventDefault();
            items[(idx + 1) % items.length].focus();
        } else if (e.key === 'ArrowUp') {
            e.preventDefault();
            items[(idx - 1 + items.length) % items.length].focus();
        } else if (e.key === 'Home') {
            e.preventDefault();
            items[0].focus();
        } else if (e.key === 'End') {
            e.preventDefault();
            items[items.length - 1].focus();
        } else if (e.key === 'Enter') {
            e.preventDefault();
            if (idx >= 0) items[idx].click();
        }
    });

    // Item click closes
    content.querySelectorAll('[data-publr-part="item"]').forEach(item => {
        item.addEventListener('click', () => {
            close(el);
            trigger.focus();
        });
    });
});

// ── Select ──────────────────────────────────────
register('select', (el) => {
    const trigger = el.querySelector('[data-publr-part="trigger"]');
    const content = el.querySelector('[data-publr-part="content"]');
    const hidden = el.querySelector('[data-publr-part="value"]');
    const label = el.querySelector('[data-publr-part="label"]');
    if (!trigger || !content) return;
    el._publrContent = content;

    trigger.addEventListener('click', () => {
        if (isOpen(el)) {
            close(el);
        } else {
            open(el);
            portal(content);
            position(content, trigger);
            el._publrOnClose = () => unportal(content);
            const selected = content.querySelector('[aria-selected="true"]') || content.querySelector('[data-publr-part="item"]');
            if (selected) selected.focus();
        }
    });

    // Keyboard navigation + type-ahead
    let typeBuffer = '';
    let typeTimer = null;
    content.addEventListener('keydown', (e) => {
        const items = content.querySelectorAll('[data-publr-part="item"]');
        if (!items.length) return;
        const idx = Array.from(items).indexOf(document.activeElement);

        if (e.key === 'ArrowDown') {
            e.preventDefault();
            items[(idx + 1) % items.length].focus();
        } else if (e.key === 'ArrowUp') {
            e.preventDefault();
            items[(idx - 1 + items.length) % items.length].focus();
        } else if (e.key === 'Home') {
            e.preventDefault();
            items[0].focus();
        } else if (e.key === 'End') {
            e.preventDefault();
            items[items.length - 1].focus();
        } else if (e.key === 'Enter') {
            e.preventDefault();
            if (idx >= 0) items[idx].click();
        } else if (e.key.length === 1 && !e.ctrlKey && !e.metaKey) {
            typeBuffer += e.key.toLowerCase();
            clearTimeout(typeTimer);
            typeTimer = setTimeout(() => { typeBuffer = ''; }, 500);
            for (const item of items) {
                if (item.textContent.trim().toLowerCase().startsWith(typeBuffer)) {
                    item.focus();
                    break;
                }
            }
        }
    });

    // Item selection
    content.querySelectorAll('[data-publr-part="item"]').forEach(item => {
        item.addEventListener('click', function() {
            const val = this.dataset.value;
            const text = this.textContent;
            if (hidden) hidden.value = val;
            if (label) label.textContent = text;
            content.querySelectorAll('[data-publr-part="item"]').forEach(i => {
                i.setAttribute('aria-selected', i === this ? 'true' : 'false');
            });
            close(el);
            trigger.focus();
        });
    });
});

// ── Popover ─────────────────────────────────────
register('popover', (el) => {
    const trigger = el.querySelector('[data-publr-part="trigger"]');
    const content = el.querySelector('[data-publr-part="content"]');
    if (!trigger || !content) return;
    el._publrContent = content;
    const id = nextId('popover');
    content.id = id;
    trigger.setAttribute('aria-controls', id);

    trigger.addEventListener('click', () => {
        if (isOpen(el)) {
            close(el);
        } else {
            open(el);
            portal(content);
            position(content, trigger);
            el._publrOnClose = () => unportal(content);
        }
    });
});

// ── Tooltip ─────────────────────────────────────
// Tooltips manage state directly — no openStack interaction.
// They respond only to hover/focus, not click-outside or Escape.
register('tooltip', (el) => {
    const trigger = el.querySelector('[data-publr-part="trigger"]');
    const content = el.querySelector('[data-publr-part="content"]');
    if (!trigger || !content) return;
    const id = nextId('tooltip');
    content.id = id;
    trigger.setAttribute('aria-describedby', id);
    let timer = null;

    function show() {
        timer = setTimeout(() => {
            el.dataset.publrState = 'open';
            portal(content);
            position(content, trigger);
        }, 200);
    }

    function hide() {
        clearTimeout(timer);
        if (el.dataset.publrState === 'open') {
            el.dataset.publrState = 'closed';
            unportal(content);
        }
    }

    trigger.addEventListener('mouseenter', show);
    trigger.addEventListener('mouseleave', hide);
    trigger.addEventListener('focus', show);
    trigger.addEventListener('blur', hide);
    trigger.addEventListener('keydown', (e) => {
        if (e.key === 'Escape') hide();
    });
});

// ── Toast ───────────────────────────────────────
let toastRegion = null;

function getToastRegion() {
    if (!toastRegion) {
        toastRegion = document.createElement('div');
        toastRegion.className = 'toast-region';
        toastRegion.setAttribute('aria-live', 'polite');
        document.body.appendChild(toastRegion);
    }
    return toastRegion;
}

function dismissToast(toast) {
    toast.classList.remove('toast-visible');
    toast.classList.add('toast-exit');
    setTimeout(() => {
        if (toast.parentNode) toast.parentNode.removeChild(toast);
    }, 300);
}

export function toast(message, variant) {
    const region = getToastRegion();
    const toastEl = document.createElement('div');
    toastEl.className = 'toast toast-' + (variant || 'info');
    toastEl.setAttribute('role', 'status');

    const text = document.createElement('span');
    text.textContent = message;
    toastEl.appendChild(text);

    const closeBtn = document.createElement('button');
    closeBtn.className = 'toast-close';
    closeBtn.setAttribute('aria-label', 'Dismiss');
    closeBtn.textContent = '\u00d7';
    let autoTimer;
    closeBtn.addEventListener('click', () => {
        clearTimeout(autoTimer);
        dismissToast(toastEl);
    });
    toastEl.appendChild(closeBtn);

    region.appendChild(toastEl);

    requestAnimationFrame(() => {
        toastEl.classList.add('toast-visible');
    });

    autoTimer = setTimeout(() => {
        dismissToast(toastEl);
    }, 4000);
}

// ── Tabs ────────────────────────────────────────
register('tabs', (el) => {
    const triggers = el.querySelectorAll('[data-publr-part="trigger"]');
    const panels = el.querySelectorAll('[data-publr-part="panel"]');

    // Wire up aria-controls / aria-labelledby with generated IDs
    triggers.forEach(trigger => {
        const tabId = trigger.dataset.publrTab;
        const triggerId = nextId('tab');
        const panelId = nextId('tabpanel');
        trigger.id = triggerId;
        trigger.setAttribute('aria-controls', panelId);
        panels.forEach(panel => {
            if (panel.dataset.publrTab === tabId) {
                panel.id = panelId;
                panel.setAttribute('aria-labelledby', triggerId);
            }
        });
    });

    function activate(tab) {
        const id = tab.dataset.publrTab;
        triggers.forEach(t => {
            t.setAttribute('aria-selected', t === tab ? 'true' : 'false');
            t.setAttribute('tabindex', t === tab ? '0' : '-1');
        });
        panels.forEach(p => {
            if (p.dataset.publrTab === id) {
                p.removeAttribute('hidden');
            } else {
                p.setAttribute('hidden', 'true');
            }
        });
    }

    triggers.forEach(trigger => {
        trigger.addEventListener('click', () => activate(trigger));
    });

    el.addEventListener('keydown', (e) => {
        if (e.target.dataset.publrPart !== 'trigger') return;
        const idx = Array.from(triggers).indexOf(e.target);
        if (e.key === 'ArrowRight') {
            e.preventDefault();
            const next = triggers[(idx + 1) % triggers.length];
            next.focus();
            activate(next);
        } else if (e.key === 'ArrowLeft') {
            e.preventDefault();
            const prev = triggers[(idx - 1 + triggers.length) % triggers.length];
            prev.focus();
            activate(prev);
        } else if (e.key === 'Home') {
            e.preventDefault();
            triggers[0].focus();
            activate(triggers[0]);
        } else if (e.key === 'End') {
            e.preventDefault();
            triggers[triggers.length - 1].focus();
            activate(triggers[triggers.length - 1]);
        }
    });
});

// ── Switch ──────────────────────────────────────
register('switch', (el) => {
    const input = el.querySelector('[data-publr-part="input"]');
    const track = el.querySelector('[data-publr-part="track"]');
    if (!input || !track) return;

    function sync() {
        track.setAttribute('aria-checked', input.checked ? 'true' : 'false');
    }

    input.addEventListener('change', sync);
    sync();
});

// ── Checkbox Group ──────────────────────────────
register('checkbox-group', () => {
    // Semantic HTML handles behavior
});

// ── Radio Group ─────────────────────────────────
register('radio-group', (el) => {
    el.addEventListener('keydown', (e) => {
        if (e.key !== 'ArrowDown' && e.key !== 'ArrowUp') return;
        const radios = el.querySelectorAll('input[type="radio"]');
        if (!radios.length) return;
        const idx = Array.from(radios).indexOf(document.activeElement);
        if (idx === -1) return;
        e.preventDefault();
        let next;
        if (e.key === 'ArrowDown') {
            next = radios[(idx + 1) % radios.length];
        } else {
            next = radios[(idx - 1 + radios.length) % radios.length];
        }
        next.checked = true;
        next.focus();
        next.dispatchEvent(new Event('change', { bubbles: true }));
    });
});

// ── Focal Point ────────────────────────────────
register('focal-point', (el) => {
    const img = el.querySelector('[data-publr-part="image"]');
    const marker = el.querySelector('[data-publr-part="marker"]');
    const label = el.querySelector('[data-publr-part="label"]');
    const inputId = el.dataset.publrInput;
    const input = inputId ? document.getElementById(inputId) : null;
    if (!img || !marker) return;

    function set(x, y) {
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

    // Initialize from data attribute
    const initial = el.dataset.publrValue;
    if (initial && initial.indexOf(',') !== -1) {
        const parts = initial.split(',');
        set(parseFloat(parts[0]), parseFloat(parts[1]));
    } else {
        set(50, 50);
    }

    el.addEventListener('click', (e) => {
        const rect = img.getBoundingClientRect();
        const x = ((e.clientX - rect.left) / rect.width) * 100;
        const y = ((e.clientY - rect.top) / rect.height) * 100;
        set(x, y);
    });
});

// ── Inline Create ──────────────────────────────
register('inline-create', (el) => {
    const targetId = el.dataset.publrTarget;
    if (!targetId) return;
    const form = document.getElementById(targetId);
    if (!form) return;

    function showForm() {
        form.style.display = '';
        const input = form.querySelector('input[type="text"]');
        if (input) input.focus();
    }

    function hideForm() {
        form.style.display = 'none';
    }

    el.addEventListener('click', (e) => {
        e.preventDefault();
        if (form.style.display === 'none') {
            showForm();
        } else {
            hideForm();
        }
    });

    form.addEventListener('keydown', (e) => {
        if (e.key === 'Escape') {
            hideForm();
            el.focus();
        }
    });
});

// ── Tag Picker ─────────────────────────────────
register('tag-picker', (el) => {
    const selectedContainer = el.querySelector('[data-publr-part="selected"]');
    const searchInput = el.querySelector('[data-publr-part="search"]');
    const dropdown = el.querySelector('[data-publr-part="dropdown"]');
    const optionsContainer = el.querySelector('[data-publr-part="options"]');
    const createBtn = el.querySelector('[data-publr-part="create"]');
    const hidden = el.querySelector('[data-publr-part="hidden"]');
    if (!searchInput || !dropdown || !hidden) return;

    function syncHidden() {
        const names = [];
        selectedContainer.querySelectorAll('.tag-picker-chip').forEach(chip => {
            names.push(chip.dataset.tagName);
        });
        hidden.value = names.join(', ');
    }

    function addChip(name, id) {
        // Check if chip already exists
        const existing = selectedContainer.querySelector('[data-tag-name="' + name + '"]');
        if (existing) return;

        const chip = document.createElement('span');
        chip.className = 'tag-picker-chip';
        chip.dataset.tagName = name;
        if (id) chip.dataset.tagId = id;
        else chip.dataset.tagCustom = 'true';
        chip.textContent = name;

        const removeBtn = document.createElement('button');
        removeBtn.type = 'button';
        removeBtn.className = 'tag-picker-chip-remove';
        removeBtn.setAttribute('aria-label', 'Remove tag');
        removeBtn.innerHTML = '&times;';
        removeBtn.addEventListener('click', () => {
            chip.remove();
            // Uncheck matching option
            const cb = optionsContainer.querySelector('input[value="' + name + '"]');
            if (cb) cb.checked = false;
            syncHidden();
        });

        chip.appendChild(removeBtn);
        selectedContainer.appendChild(chip);
    }

    function removeChip(name) {
        const chip = selectedContainer.querySelector('[data-tag-name="' + name + '"]');
        if (chip) chip.remove();
    }

    // Wire existing remove buttons on server-rendered chips
    selectedContainer.querySelectorAll('[data-publr-part="remove"]').forEach(btn => {
        btn.addEventListener('click', () => {
            const chip = btn.closest('.tag-picker-chip');
            const name = chip.dataset.tagName;
            chip.remove();
            const cb = optionsContainer.querySelector('input[value="' + name + '"]');
            if (cb) cb.checked = false;
            syncHidden();
        });
    });

    // Checkbox changes
    optionsContainer.querySelectorAll('[data-publr-part="option"]').forEach(cb => {
        cb.addEventListener('change', () => {
            if (cb.checked) {
                addChip(cb.value, cb.dataset.tagId);
            } else {
                removeChip(cb.value);
            }
            syncHidden();
        });
    });

    // Search input
    searchInput.addEventListener('focus', () => {
        dropdown.style.display = '';
        filterOptions();
    });

    searchInput.addEventListener('input', () => {
        filterOptions();
    });

    function filterOptions() {
        const query = searchInput.value.trim().toLowerCase();
        let hasExactMatch = false;
        const options = optionsContainer.querySelectorAll('.tag-picker-option');
        options.forEach(opt => {
            const name = opt.querySelector('input').value.toLowerCase();
            if (query.length === 0 || name.indexOf(query) !== -1) {
                opt.style.display = '';
            } else {
                opt.style.display = 'none';
            }
            if (name === query) hasExactMatch = true;
        });

        if (query.length > 0 && !hasExactMatch) {
            createBtn.textContent = 'Create tag: ' + searchInput.value.trim();
            createBtn.style.display = '';
        } else {
            createBtn.style.display = 'none';
        }
    }

    // Create button
    if (createBtn) {
        createBtn.addEventListener('click', () => {
            const name = searchInput.value.trim();
            if (name.length === 0) return;
            addChip(name, null);
            searchInput.value = '';
            createBtn.style.display = 'none';
            filterOptions();
            syncHidden();
        });
    }

    // Enter key triggers create
    searchInput.addEventListener('keydown', (e) => {
        if (e.key === 'Enter') {
            e.preventDefault();
            if (createBtn && createBtn.style.display !== 'none') {
                createBtn.click();
            }
        } else if (e.key === 'Escape') {
            dropdown.style.display = 'none';
            searchInput.blur();
        }
    });

    // Click outside closes dropdown
    document.addEventListener('click', (e) => {
        if (!el.contains(e.target)) {
            dropdown.style.display = 'none';
        }
    });
});

// ── Nav Slider ─────────────────────────────────
register('nav-slider', (el) => {
    const slider = el.querySelector('.nav-slider');
    const triggers = el.querySelectorAll('[data-publr-part="trigger"]');
    const backBtns = el.querySelectorAll('[data-publr-part="back"]');
    if (!slider) return;

    triggers.forEach(trigger => {
        trigger.addEventListener('click', () => {
            slider.classList.add('submenu-open');
        });
    });

    backBtns.forEach(btn => {
        btn.addEventListener('click', () => {
            slider.classList.remove('submenu-open');
        });
    });
});
