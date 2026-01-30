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
