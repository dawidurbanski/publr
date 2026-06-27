// KV variable picker — type `$` in an opted-in text input/textarea to open a
// searchable dropdown that inserts `[kv:varname]` tokens.
//
// Wired through the interact runtime's delegated events: a single document
// listener per event type (keydown / input / focusout) dispatches to matching
// inputs via closest(). Works for inputs swapped in by HMR with no per-element
// binding and no listener accumulation.
//
// Variable data is loaded from a `<script id="kv-vars-data" type="application/json">`
// element on the page. Each item: { key, label, description, mode, source, value }.

import { delegate } from './core.js';

var TRIGGER_CHAR = '$';

// Inputs the picker attaches to: explicit opt-in via data attribute, plus
// every text input/textarea inside the content entry edit form.
var SELECTOR = [
    'input[type="text"][data-publr-kv-picker]',
    'textarea[data-publr-kv-picker]',
    '#entry-form input[type="text"]',
    '#entry-form textarea',
].join(', ');

// -------------------------------------------------------------------------
// Data loading (page-global; cached once — same vars for every input)
// -------------------------------------------------------------------------

var varsCache = null;
function vars() {
    if (varsCache === null) varsCache = loadVars();
    return varsCache;
}

function loadVars() {
    var node = document.getElementById('kv-vars-data');
    if (!node) return [];
    try {
        return JSON.parse(node.textContent || '[]');
    } catch (e) {
        console.warn('kv-picker: failed to parse kv-vars-data JSON', e);
        return [];
    }
}

function isIdentChar(c) {
    return /^[a-zA-Z0-9_.]$/.test(c);
}

// -------------------------------------------------------------------------
// Dropdown UI
// -------------------------------------------------------------------------

function createDropdown() {
    var el = document.createElement('div');
    el.className = 'publr-kv-picker';
    el.style.cssText = [
        'position: absolute',
        'z-index: 1000',
        'min-width: 260px',
        'max-width: 360px',
        'max-height: 280px',
        'overflow-y: auto',
        'background: var(--popover-bg, #fff)',
        'border: 1px solid var(--border, #d4d4d8)',
        'border-radius: 6px',
        'box-shadow: 0 4px 12px rgba(0,0,0,0.08)',
        'font-size: 13px',
        'padding: 4px 0',
        'display: none',
    ].join(';');
    document.body.appendChild(el);
    return el;
}

function positionBelow(dropdown, anchorEl) {
    var rect = anchorEl.getBoundingClientRect();
    var scrollY = window.pageYOffset || document.documentElement.scrollTop;
    var scrollX = window.pageXOffset || document.documentElement.scrollLeft;
    dropdown.style.top = (rect.bottom + scrollY + 4) + 'px';
    dropdown.style.left = (rect.left + scrollX) + 'px';
}

function renderItems(dropdown, items, selectedIdx) {
    if (items.length === 0) {
        dropdown.innerHTML = '<div style="padding:8px 12px;color:#71717a">No matching variables</div>';
        return;
    }
    var html = '';
    var lastSection = null;
    for (var i = 0; i < items.length; i++) {
        var v = items[i];
        var section = v.source === 'editor' ? 'editor' : 'plugin';
        if (section !== lastSection) {
            var label = section === 'editor' ? 'Your variables' : 'Plugin variables';
            html += '<div style="padding:6px 12px;font-size:11px;color:#71717a;text-transform:uppercase;letter-spacing:0.05em;font-weight:600">' + label + '</div>';
            lastSection = section;
        }
        var sel = i === selectedIdx;
        var rowBg = sel ? 'var(--accent, #f4f4f5)' : 'transparent';
        var valuePreview = (v.value || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').slice(0, 40);
        var sourceTag = v.source === 'editor' ? '' :
            '<span style="font-size:10px;color:#71717a;margin-left:6px">' + escapeText(v.source) + '</span>';
        var labelText = v.label && v.label.length > 0 ? v.label : '';
        html += '<div class="kv-picker-item" data-idx="' + i + '" ' +
            'style="padding:6px 12px;cursor:pointer;background:' + rowBg + '">' +
            '<div style="display:flex;align-items:center;gap:6px">' +
            '<span style="font-family:ui-monospace,monospace;font-size:12px">' + escapeText(v.key) + '</span>' +
            (labelText ? '<span style="color:#71717a;font-size:12px">— ' + escapeText(labelText) + '</span>' : '') +
            sourceTag +
            '</div>' +
            (valuePreview ? '<div style="color:#71717a;font-size:11px;margin-top:2px">' + valuePreview + '</div>' : '') +
            '</div>';
    }
    dropdown.innerHTML = html;
}

function escapeText(s) {
    return String(s || '')
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;');
}

// -------------------------------------------------------------------------
// Session — one open picker at a time, tracked here.
// -------------------------------------------------------------------------

var session = null;

function startSession(input, vs) {
    var dropdown = createDropdown();
    session = {
        input: input,
        vars: vs,
        dropdown: dropdown,
        // Anchor: position of the `$` in the input. We replace from anchor
        // through current cursor when inserting.
        anchorPos: input.selectionStart - 1,
        filtered: [],
        selectedIdx: 0,
    };
    positionBelow(dropdown, input);
    refresh();
    dropdown.style.display = 'block';
    // Click handler on items (scoped to this dropdown element — disposed with it).
    dropdown.addEventListener('mousedown', function (e) {
        var target = e.target;
        while (target && target !== dropdown && !target.dataset.idx) {
            target = target.parentElement;
        }
        if (target && target.dataset && target.dataset.idx) {
            e.preventDefault(); // keep focus in the input
            session.selectedIdx = parseInt(target.dataset.idx, 10);
            insert();
        }
    });
}

function endSession() {
    if (!session) return;
    session.dropdown.parentNode.removeChild(session.dropdown);
    session = null;
}

function getFilterText() {
    if (!session) return '';
    var cursor = session.input.selectionStart;
    // anchorPos points at the `$`; filter is everything between
    // (anchor + 1) and the current cursor.
    if (cursor <= session.anchorPos) return '';
    return session.input.value.slice(session.anchorPos + 1, cursor);
}

function refresh() {
    if (!session) return;
    var q = getFilterText().toLowerCase();
    session.filtered = session.vars.filter(function (v) {
        if (!q) return true;
        var hay = (v.key + ' ' + (v.label || '')).toLowerCase();
        return hay.indexOf(q) !== -1;
    });
    // Sort: editor vars first, then plugin vars, each alphabetical.
    session.filtered.sort(function (a, b) {
        var aEd = a.source === 'editor' ? 0 : 1;
        var bEd = b.source === 'editor' ? 0 : 1;
        if (aEd !== bEd) return aEd - bEd;
        return a.key.localeCompare(b.key);
    });
    if (session.selectedIdx >= session.filtered.length) {
        session.selectedIdx = 0;
    }
    renderItems(session.dropdown, session.filtered, session.selectedIdx);
}

function insert() {
    if (!session || session.filtered.length === 0) return;
    var v = session.filtered[session.selectedIdx];
    var token = '[kv:' + v.key + ']';
    var input = session.input;
    var anchor = session.anchorPos;
    var cursor = input.selectionStart;
    var before = input.value.slice(0, anchor);
    var after = input.value.slice(cursor);
    input.value = before + token + after;
    // Place cursor right after the inserted token.
    var newPos = anchor + token.length;
    input.setSelectionRange(newPos, newPos);
    // Fire input event so any autosave / change-tracking hooks pick it up.
    input.dispatchEvent(new Event('input', { bubbles: true }));
    endSession();
}

// -------------------------------------------------------------------------
// Delegated event wiring — one document listener per event type, dispatched
// to matching inputs. `focusout` (which bubbles) replaces the per-element
// `blur` (which does not).
// -------------------------------------------------------------------------

delegate('keydown', SELECTOR, function (e, input) {
    // Active picker: arrow/enter/esc handling
    if (session && session.input === input) {
        if (e.key === 'Escape') {
            e.preventDefault();
            endSession();
            return;
        }
        if (e.key === 'ArrowDown') {
            e.preventDefault();
            session.selectedIdx = Math.min(session.selectedIdx + 1, session.filtered.length - 1);
            renderItems(session.dropdown, session.filtered, session.selectedIdx);
            return;
        }
        if (e.key === 'ArrowUp') {
            e.preventDefault();
            session.selectedIdx = Math.max(session.selectedIdx - 1, 0);
            renderItems(session.dropdown, session.filtered, session.selectedIdx);
            return;
        }
        if (e.key === 'Enter' || e.key === 'Tab') {
            if (session.filtered.length > 0) {
                e.preventDefault();
                insert();
                return;
            }
        }
        // Backspace through the `$` — close session.
        if (e.key === 'Backspace' && input.selectionStart <= session.anchorPos + 1) {
            endSession();
            return;
        }
        // Typing a non-identifier char — close session (don't insert).
        if (e.key.length === 1 && !isIdentChar(e.key)) {
            endSession();
            return;
        }
        return;
    }
    // No active session: detect `$` open.
    if (e.key === TRIGGER_CHAR && !e.ctrlKey && !e.metaKey && !e.altKey) {
        // Defer to next tick so the `$` is already in input.value and
        // selectionStart has advanced past it.
        setTimeout(function () {
            startSession(input, vars());
        }, 0);
    }
});

delegate('input', SELECTOR, function (e, input) {
    if (session && session.input === input) {
        refresh();
    }
});

delegate('focusout', SELECTOR, function (e, input) {
    // Small delay so click-on-item still works (item mousedown closes via
    // insert() first).
    setTimeout(function () {
        if (session && session.input === input) endSession();
    }, 150);
});
