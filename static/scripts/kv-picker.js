// KV variable picker — type `$` in an opted-in text input/textarea to open a
// searchable listbox that inserts `[kv:varname]` tokens at the caret
// (PublrJS store; the listbox shell is src/views/components/kv_picker.zsx,
// rendered once per page next to the #kv-vars-data JSON it reads).
//
// This is a combobox, not a dropdown: the load-bearing parts are the
// caret-anchored replacement (everything from the `$` through the cursor is
// swapped for the token), keyboard selection (arrows/enter/tab/escape), the
// 150ms focusout grace so mousedown-on-item still wins, and fixed
// positioning below the input (the listbox is portalled to <body>).
//
// Inputs are not wired declaratively — the picker attaches to arbitrary
// form fields via document-level listeners bound in setup() (removed on
// island teardown), dispatched through closest(SELECTOR) like the legacy
// delegated runtime did. Works for inputs swapped in by HMR with no
// per-element binding and no listener accumulation.

import { Publr } from '/static/scripts/publr.js';
import { position } from '/static/scripts/publr-position.js';

const TRIGGER_CHAR = '$';

// Inputs the picker attaches to: explicit opt-in via data attribute, plus
// every text input/textarea inside the content entry edit form.
const SELECTOR = [
    'input[type="text"][data-publr-kv-picker]',
    'textarea[data-publr-kv-picker]',
    '#entry-form input[type="text"]',
    '#entry-form textarea',
].join(', ');

function isIdentChar(c) {
    return /^[a-zA-Z0-9_.]$/.test(c);
}

Publr.store('kv-picker', () => {
    const state = Publr.reactive({
        open: false,
        items: [],
        empty: false,
    });

    let el = null;
    // Captured in setup() BEFORE hydration portals the node to <body> —
    // after that it is no longer inside `el`, so a live querySelector on the
    // island would come up empty.
    let listboxEl = null;
    let vars = null; // parsed #kv-vars-data (lazy — same vars for every input)
    let input = null; // the session's input; null = closed
    let anchorPos = 0; // index of the `$` in input.value
    let filtered = [];
    let selectedIdx = 0;
    let blurTimer = null;

    function loadVars() {
        const node = document.getElementById('kv-vars-data');
        if (!node) return [];
        try {
            return JSON.parse(node.textContent || '[]');
        } catch (e) {
            console.warn('kv-picker: failed to parse kv-vars-data JSON', e);
            return [];
        }
    }

    function filterText() {
        const cursor = input.selectionStart;
        // anchorPos points at the `$`; filter is everything between
        // (anchor + 1) and the current cursor.
        if (cursor <= anchorPos) return '';
        return input.value.slice(anchorPos + 1, cursor);
    }

    function render() {
        let lastSection = null;
        state.items = filtered.map((v, i) => {
            const section = v.source === 'editor' ? 'editor' : 'plugin';
            const hasHeader = section !== lastSection;
            lastSection = section;
            return {
                id: String(i),
                key: v.key,
                hasLabel: !!(v.label && v.label.length),
                labelText: v.label ? '— ' + v.label : '',
                source: v.source,
                isPlugin: v.source !== 'editor',
                hasHeader,
                headerLabel: section === 'editor' ? 'Your variables' : 'Plugin variables',
                hasValue: !!(v.value && v.value.length),
                valuePreview: (v.value || '').slice(0, 40),
                selected: i === selectedIdx,
            };
        });
        state.empty = filtered.length === 0;
    }

    function refresh() {
        const q = filterText().toLowerCase();
        filtered = vars.filter((v) => {
            if (!q) return true;
            return (v.key + ' ' + (v.label || '')).toLowerCase().indexOf(q) !== -1;
        });
        // Sort: editor vars first, then plugin vars, each alphabetical.
        filtered.sort((a, b) => {
            const aEd = a.source === 'editor' ? 0 : 1;
            const bEd = b.source === 'editor' ? 0 : 1;
            if (aEd !== bEd) return aEd - bEd;
            return a.key.localeCompare(b.key);
        });
        if (selectedIdx >= filtered.length) selectedIdx = 0;
        render();
    }

    function setSelected(idx) {
        selectedIdx = idx;
        state.items.forEach((it, i) => { it.selected = i === idx; });
        const row = listboxEl && listboxEl.querySelector('[data-idx="' + idx + '"]');
        if (row && row.scrollIntoView) row.scrollIntoView({ block: 'nearest' });
    }

    // Effects (and @for stamping) are microtask-batched — measure/position
    // only after the listbox is visible and holds its rows, so the rect (and
    // the flip decision) are real. Deduped: scroll can fire many times per
    // frame.
    let positionQueued = false;
    function schedulePosition() {
        if (positionQueued) return;
        positionQueued = true;
        queueMicrotask(() => {
            positionQueued = false;
            if (!state.open || !input || !listboxEl) return;
            position(listboxEl, input, { placement: 'bottom-start', offset: 4 });
        });
    }

    function open(target) {
        if (vars === null) vars = loadVars();
        clearTimeout(blurTimer);
        input = target;
        anchorPos = target.selectionStart - 1;
        selectedIdx = 0;
        refresh();
        state.open = true;
        schedulePosition();
    }

    function close() {
        input = null;
        state.open = false;
    }

    function insert() {
        if (!input || filtered.length === 0) return;
        const v = filtered[selectedIdx];
        const token = '[kv:' + v.key + ']';
        const target = input;
        const anchor = anchorPos;
        const cursor = target.selectionStart;
        close();
        target.value = target.value.slice(0, anchor) + token + target.value.slice(cursor);
        // Place cursor right after the inserted token.
        const newPos = anchor + token.length;
        target.setSelectionRange(newPos, newPos);
        // Fire input event so any autosave / change-tracking hooks pick it up.
        target.dispatchEvent(new Event('input', { bubbles: true }));
    }

    const actions = {
        // mousedown (with .prevent so focus stays in the input) on a stamped
        // row — the row's data-idx rides in via the action's dataset bag.
        pickItem: (d) => {
            const idx = parseInt(d.idx, 10);
            if (isNaN(idx) || !input) return;
            selectedIdx = idx;
            insert();
        },
    };

    return {
        state,
        actions,
        setup: ({ el: root }) => {
            el = root;
            // Grab the listbox now — setup() runs before directive wiring,
            // so @portal hasn't moved it out of the island yet.
            listboxEl = root.querySelector('[data-publr-part="listbox"]');

            const onKeydown = (e) => {
                const target = e.target && e.target.closest ? e.target.closest(SELECTOR) : null;
                if (!target) return;
                // Active session on this input: selection/close keys.
                if (input && target === input) {
                    if (e.key === 'Escape') {
                        e.preventDefault();
                        close();
                        return;
                    }
                    if (e.key === 'ArrowDown') {
                        e.preventDefault();
                        setSelected(Math.min(selectedIdx + 1, filtered.length - 1));
                        return;
                    }
                    if (e.key === 'ArrowUp') {
                        e.preventDefault();
                        setSelected(Math.max(selectedIdx - 1, 0));
                        return;
                    }
                    if (e.key === 'Enter' || e.key === 'Tab') {
                        if (filtered.length > 0) {
                            e.preventDefault();
                            insert();
                        }
                        return;
                    }
                    // Backspace through the `$` — close.
                    if (e.key === 'Backspace' && input.selectionStart <= anchorPos + 1) {
                        close();
                        return;
                    }
                    // Typing a non-identifier char — close (don't insert).
                    if (e.key.length === 1 && !isIdentChar(e.key)) {
                        close();
                        return;
                    }
                    return;
                }
                // No session (or session on another input): detect `$` open.
                if (e.key === TRIGGER_CHAR && !e.ctrlKey && !e.metaKey && !e.altKey) {
                    // Defer to next tick so the `$` is already in target.value
                    // and selectionStart has advanced past it.
                    setTimeout(() => { if (el) open(target); }, 0);
                }
            };

            const onInput = (e) => {
                if (input && e.target === input) {
                    refresh();
                    // Filtering changes the listbox height; when it opened
                    // flipped above the input, a stale top leaves a gap.
                    schedulePosition();
                }
            };

            const onFocusout = (e) => {
                const target = e.target && e.target.closest ? e.target.closest(SELECTOR) : null;
                if (!target) return;
                // Grace period so mousedown-on-item wins (it inserts and
                // closes first; .prevent keeps focus anyway).
                blurTimer = setTimeout(() => {
                    if (input === target) close();
                }, 150);
            };

            // The listbox is position:fixed — keep it glued to the input
            // across page/container scrolls and window resizes. Capture
            // phase because scroll doesn't bubble. The listbox's own
            // overflow scrolling is exempt (repositioning mid-list-scroll
            // would flicker the visibility-toggle measurement).
            const onScroll = (e) => {
                if (!state.open) return;
                if (listboxEl && (e.target === listboxEl || (listboxEl.contains && listboxEl.contains(e.target)))) return;
                schedulePosition();
            };
            const onResize = () => { if (state.open) schedulePosition(); };

            document.addEventListener('keydown', onKeydown);
            document.addEventListener('input', onInput);
            document.addEventListener('focusout', onFocusout);
            document.addEventListener('scroll', onScroll, true);
            window.addEventListener('resize', onResize);

            return () => {
                document.removeEventListener('keydown', onKeydown);
                document.removeEventListener('input', onInput);
                document.removeEventListener('focusout', onFocusout);
                document.removeEventListener('scroll', onScroll, true);
                window.removeEventListener('resize', onResize);
                clearTimeout(blurTimer);
                el = null;
                listboxEl = null;
                input = null;
            };
        },
    };
});
