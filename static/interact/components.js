// Publr Interactivity — Component Handlers
// Registers handlers for: toggle, dialog, dropdown, select, popover, tooltip, toast, tabs, switch.
// Depends on: core.js, toggle.js, portal.js, focus-trap.js, dismiss.js.
(function() {
    'use strict';

    var publr = window.publr || {};
    var uid = 0;
    function nextId(prefix) { return 'publr-' + prefix + '-' + (++uid); }

    // ── Toggle ──────────────────────────────────────
    publr.register('toggle', function(el) {
        var trigger = el.querySelector('[data-publr-part="trigger"]');
        if (!trigger) return;
        trigger.addEventListener('click', function() {
            publr.toggle(el);
        });
    });

    // ── Dialog ──────────────────────────────────────
    publr.register('dialog', function(el) {
        var trigger = el.querySelector('[data-publr-part="trigger"]');
        var content = el.querySelector('[data-publr-part="content"]');
        var closeBtn = el.querySelector('[data-publr-part="close"]');
        if (!trigger || !content) return;

        trigger.addEventListener('click', function() {
            publr.open(el);
            publr.trapFocus(content);
            el._publrOnClose = function() {
                publr.releaseFocus(content);
                trigger.focus();
            };
        });

        if (closeBtn) {
            closeBtn.addEventListener('click', function() {
                publr.close(el);
            });
        }

        // Overlay click (only if dismissable)
        content.addEventListener('click', function(e) {
            if (e.target === content && el.dataset.publrDismissable !== 'false') {
                publr.close(el);
            }
        });
    });

    // ── Dropdown Menu ───────────────────────────────
    publr.register('dropdown', function(el) {
        var trigger = el.querySelector('[data-publr-part="trigger"]');
        var content = el.querySelector('[data-publr-part="content"]');
        if (!trigger || !content) return;

        trigger.addEventListener('click', function() {
            if (publr.isOpen(el)) {
                publr.close(el);
            } else {
                publr.open(el);
                publr.portal(content);
                publr.position(content, trigger);
                el._publrOnClose = function() {
                    publr.unportal(content);
                };
                var first = content.querySelector('[data-publr-part="item"]');
                if (first) first.focus();
            }
        });

        // Keyboard navigation
        content.addEventListener('keydown', function(e) {
            var items = content.querySelectorAll('[data-publr-part="item"]');
            if (!items.length) return;
            var idx = Array.prototype.indexOf.call(items, document.activeElement);

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
        var items = content.querySelectorAll('[data-publr-part="item"]');
        for (var i = 0; i < items.length; i++) {
            items[i].addEventListener('click', function() {
                publr.close(el);
                trigger.focus();
            });
        }
    });

    // ── Select ──────────────────────────────────────
    publr.register('select', function(el) {
        var trigger = el.querySelector('[data-publr-part="trigger"]');
        var content = el.querySelector('[data-publr-part="content"]');
        var hidden = el.querySelector('[data-publr-part="value"]');
        var label = el.querySelector('[data-publr-part="label"]');
        if (!trigger || !content) return;

        trigger.addEventListener('click', function() {
            if (publr.isOpen(el)) {
                publr.close(el);
            } else {
                publr.open(el);
                publr.portal(content);
                publr.position(content, trigger);
                el._publrOnClose = function() {
                    publr.unportal(content);
                };
                var selected = content.querySelector('[aria-selected="true"]') || content.querySelector('[data-publr-part="item"]');
                if (selected) selected.focus();
            }
        });

        // Keyboard navigation + type-ahead
        var typeBuffer = '';
        var typeTimer = null;
        content.addEventListener('keydown', function(e) {
            var items = content.querySelectorAll('[data-publr-part="item"]');
            if (!items.length) return;
            var idx = Array.prototype.indexOf.call(items, document.activeElement);

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
                typeTimer = setTimeout(function() { typeBuffer = ''; }, 500);
                for (var k = 0; k < items.length; k++) {
                    if (items[k].textContent.trim().toLowerCase().indexOf(typeBuffer) === 0) {
                        items[k].focus();
                        break;
                    }
                }
            }
        });

        // Item selection
        var items = content.querySelectorAll('[data-publr-part="item"]');
        for (var i = 0; i < items.length; i++) {
            items[i].addEventListener('click', function() {
                var val = this.dataset.value;
                var text = this.textContent;
                if (hidden) hidden.value = val;
                if (label) label.textContent = text;
                var all = content.querySelectorAll('[data-publr-part="item"]');
                for (var j = 0; j < all.length; j++) {
                    all[j].setAttribute('aria-selected', all[j] === this ? 'true' : 'false');
                }
                publr.close(el);
                trigger.focus();
            });
        }
    });

    // ── Popover ─────────────────────────────────────
    publr.register('popover', function(el) {
        var trigger = el.querySelector('[data-publr-part="trigger"]');
        var content = el.querySelector('[data-publr-part="content"]');
        if (!trigger || !content) return;
        var id = nextId('popover');
        content.id = id;
        trigger.setAttribute('aria-controls', id);

        trigger.addEventListener('click', function() {
            if (publr.isOpen(el)) {
                publr.close(el);
            } else {
                publr.open(el);
                publr.portal(content);
                publr.position(content, trigger);
                el._publrOnClose = function() {
                    publr.unportal(content);
                };
            }
        });
    });

    // ── Tooltip ─────────────────────────────────────
    // Tooltips manage state directly — no openStack interaction.
    // They respond only to hover/focus, not click-outside or Escape.
    publr.register('tooltip', function(el) {
        var trigger = el.querySelector('[data-publr-part="trigger"]');
        var content = el.querySelector('[data-publr-part="content"]');
        if (!trigger || !content) return;
        var id = nextId('tooltip');
        content.id = id;
        trigger.setAttribute('aria-describedby', id);
        var timer = null;

        function show() {
            timer = setTimeout(function() {
                el.dataset.publrState = 'open';
                publr.portal(content);
                publr.position(content, trigger);
            }, 200);
        }

        function hide() {
            clearTimeout(timer);
            if (el.dataset.publrState === 'open') {
                el.dataset.publrState = 'closed';
                publr.unportal(content);
            }
        }

        trigger.addEventListener('mouseenter', show);
        trigger.addEventListener('mouseleave', hide);
        trigger.addEventListener('focus', show);
        trigger.addEventListener('blur', hide);
        trigger.addEventListener('keydown', function(e) {
            if (e.key === 'Escape') hide();
        });
    });

    // ── Toast ───────────────────────────────────────
    var toastRegion = null;

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
        setTimeout(function() {
            if (toast.parentNode) toast.parentNode.removeChild(toast);
        }, 300);
    }

    publr.toast = function(message, variant) {
        var region = getToastRegion();
        var toast = document.createElement('div');
        toast.className = 'toast toast-' + (variant || 'info');
        toast.setAttribute('role', 'status');

        var text = document.createElement('span');
        text.textContent = message;
        toast.appendChild(text);

        var close = document.createElement('button');
        close.className = 'toast-close';
        close.setAttribute('aria-label', 'Dismiss');
        close.textContent = '\u00d7';
        close.addEventListener('click', function() {
            clearTimeout(autoTimer);
            dismissToast(toast);
        });
        toast.appendChild(close);

        region.appendChild(toast);

        requestAnimationFrame(function() {
            toast.classList.add('toast-visible');
        });

        var autoTimer = setTimeout(function() {
            dismissToast(toast);
        }, 4000);
    };

    // ── Tabs ────────────────────────────────────────
    publr.register('tabs', function(el) {
        var triggers = el.querySelectorAll('[data-publr-part="trigger"]');
        var panels = el.querySelectorAll('[data-publr-part="panel"]');

        // Wire up aria-controls / aria-labelledby with generated IDs
        for (var t = 0; t < triggers.length; t++) {
            var tabId = triggers[t].dataset.publrTab;
            var triggerId = nextId('tab');
            var panelId = nextId('tabpanel');
            triggers[t].id = triggerId;
            triggers[t].setAttribute('aria-controls', panelId);
            for (var p = 0; p < panels.length; p++) {
                if (panels[p].dataset.publrTab === tabId) {
                    panels[p].id = panelId;
                    panels[p].setAttribute('aria-labelledby', triggerId);
                }
            }
        }

        function activate(tab) {
            var id = tab.dataset.publrTab;
            for (var i = 0; i < triggers.length; i++) {
                triggers[i].setAttribute('aria-selected', triggers[i] === tab ? 'true' : 'false');
                triggers[i].setAttribute('tabindex', triggers[i] === tab ? '0' : '-1');
            }
            for (var j = 0; j < panels.length; j++) {
                if (panels[j].dataset.publrTab === id) {
                    panels[j].removeAttribute('hidden');
                } else {
                    panels[j].setAttribute('hidden', 'true');
                }
            }
        }

        for (var i = 0; i < triggers.length; i++) {
            triggers[i].addEventListener('click', function() {
                activate(this);
            });
        }

        el.addEventListener('keydown', function(e) {
            if (e.target.dataset.publrPart !== 'trigger') return;
            var idx = Array.prototype.indexOf.call(triggers, e.target);
            if (e.key === 'ArrowRight') {
                e.preventDefault();
                var next = triggers[(idx + 1) % triggers.length];
                next.focus();
                activate(next);
            } else if (e.key === 'ArrowLeft') {
                e.preventDefault();
                var prev = triggers[(idx - 1 + triggers.length) % triggers.length];
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
    publr.register('switch', function(el) {
        var input = el.querySelector('[data-publr-part="input"]');
        var track = el.querySelector('[data-publr-part="track"]');
        if (!input || !track) return;

        function sync() {
            track.setAttribute('aria-checked', input.checked ? 'true' : 'false');
        }

        input.addEventListener('change', sync);
        sync();
    });

    // ── Checkbox Group ──────────────────────────────
    publr.register('checkbox-group', function() {
        // Semantic HTML handles behavior
    });

    // ── Radio Group ─────────────────────────────────
    publr.register('radio-group', function(el) {
        el.addEventListener('keydown', function(e) {
            if (e.key !== 'ArrowDown' && e.key !== 'ArrowUp') return;
            var radios = el.querySelectorAll('input[type="radio"]');
            if (!radios.length) return;
            var idx = Array.prototype.indexOf.call(radios, document.activeElement);
            if (idx === -1) return;
            e.preventDefault();
            var next;
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

    window.publr = publr;
})();
