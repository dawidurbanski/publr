// Recompile nanobar — PublrJS store (island = the bar wrapper in
// views/admin/layout.zsx). Drives the full config-recompile-and-restart UX:
// the System page's Save & Recompile button POSTs /admin/system/config, then
// this store polls /admin/system/health until the server comes back with the
// new configText. Progress survives the restart via sessionStorage and is
// resumed by setup() on every page load.
//
// Distinct from the dev HMR pill (src/dev.zig) — that one live-swaps views
// over /__hmr/ws during `zig` development; this is the user-facing
// production recompile flow.

import { Publr } from '/static/scripts/publr.js';

const STORAGE_KEY = 'publr_recompile';

Publr.store('recompile-bar', () => {
    const state = Publr.reactive({
        visible: false,
        text: '',
        normal: false, // mutually exclusive bg classes — exactly one is true
        success: false,
        error: false,
        hasAction: false,
        actionLabel: '',
    });

    let pollTimer = null;
    let gen = 0; // invalidates in-flight polls on teardown
    let onAction = null;

    function show(text, kind) {
        state.text = text;
        state.success = kind === 'success';
        state.error = kind === 'error';
        state.normal = !state.success && !state.error;
        state.hasAction = false;
        onAction = null;
        state.visible = true;
        document.body.classList.add('pt-9');
    }

    function showAction(label, fn) {
        state.actionLabel = label;
        state.hasAction = true;
        onAction = fn;
    }

    function hide() {
        state.visible = false;
        document.body.classList.remove('pt-9');
    }

    function clearStored() { sessionStorage.removeItem(STORAGE_KEY); }
    function getStored() {
        try { return JSON.parse(sessionStorage.getItem(STORAGE_KEY)); } catch (e) { return null; }
    }
    function setStored(obj) { sessionStorage.setItem(STORAGE_KEY, JSON.stringify(obj)); }

    function poll(expected, startTime) {
        const g = gen;
        fetch('/admin/system/health', { cache: 'no-store' })
            .then((r) => {
                if (!r.ok) throw new Error();
                return r.json();
            })
            .then((d) => {
                if (g !== gen) return;
                if (d.configText === expected) {
                    setStored({ state: 'done' });
                    show('Site rebuilt successfully.', 'success');
                    showAction('Refresh page', () => {
                        clearStored();
                        location.reload();
                    });
                } else {
                    schedulePoll(expected, startTime);
                }
            })
            .catch(() => {
                if (g === gen) schedulePoll(expected, startTime);
            });
    }

    function schedulePoll(expected, startTime) {
        pollTimer = setTimeout(() => {
            const elapsed = Math.round((Date.now() - startTime) / 1000);
            if (elapsed >= 5) show('Rebuilding site… (' + elapsed + 's)', null);
            poll(expected, startTime);
        }, 500);
    }

    // The Save & Recompile button lives on the System page, outside this
    // island — bind it imperatively (re-checked on publr:init for HMR swaps).
    function bindButton() {
        const btn = document.getElementById('recompile-btn');
        const input = document.querySelector('input[name="config-text"]');
        const csrfEl = document.querySelector('input[name="_csrf"]');
        if (!btn || !input || !csrfEl || btn.__publrRecompileBound) return;
        btn.__publrRecompileBound = true;

        btn.addEventListener('click', () => {
            const configText = input.value;
            const startTime = Date.now();

            btn.disabled = true;
            btn.textContent = 'Compiling…';
            setStored({ state: 'building', configText: configText, startTime: startTime });
            show('Rebuilding site…', null);

            function fail(message) {
                setStored({ state: 'error', message: message });
                show(message || 'Build failed.', 'error');
                showAction('Dismiss', () => { clearStored(); hide(); });
                btn.disabled = false;
                btn.textContent = 'Save & Recompile';
            }

            fetch('/admin/system/config', {
                method: 'POST',
                headers: {
                    'X-CSRF-Token': csrfEl.value,
                    'Content-Type': 'application/x-www-form-urlencoded',
                },
                body: 'key=configText&value=' + encodeURIComponent(configText),
            })
                .then((r) => r.text())
                .then((text) => {
                    let data;
                    try { data = JSON.parse(text); } catch (e) { fail(text || 'Unknown error'); return; }
                    if (!data.success) { fail(data.error); return; }
                    btn.textContent = 'Restarting…';
                    poll(configText, startTime);
                })
                .catch(() => {
                    // Connection lost — server is restarting, start polling
                    btn.textContent = 'Restarting…';
                    poll(configText, startTime);
                });
        });
    }

    return {
        state,
        actions: {
            actionClick: () => { if (onAction) onAction(); },
        },
        setup: () => {
            // Resume state on every page load
            const saved = getStored();
            if (saved) {
                if (saved.state === 'building') {
                    show('Rebuilding site…', null);
                    poll(saved.configText, saved.startTime);
                } else if (saved.state === 'done') {
                    show('Site rebuilt successfully.', 'success');
                    showAction('Refresh page', () => { clearStored(); location.reload(); });
                } else if (saved.state === 'error') {
                    show(saved.message || 'Build failed.', 'error');
                    showAction('Dismiss', () => { clearStored(); hide(); });
                }
            }

            bindButton();
            const onInit = () => bindButton();
            document.addEventListener('publr:init', onInit);

            return () => {
                document.removeEventListener('publr:init', onInit);
                clearTimeout(pollTimer);
                gen++;
            };
        },
    };
});
