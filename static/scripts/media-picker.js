// Media picker — PublrJS store driving the ZSX-rendered dialog
// (src/views/components/media_picker.zsx, rendered once per admin layout).
//
// Two entry points share this store:
//   * window.PublrAdmin.pickMedia({accept, selectedId}) → Promise<record|null>
//     — used by the block editor's media adapter and image-picker form fields.
//   * The store's own actions (search/filter/upload/select) wired via data-p-*.
//
// Record shape: {id, url, thumb_url, alt_text, width, height, filename};
// resolves null on cancel (close button, Cancel, Escape, backdrop).

import { Publr } from '/static/scripts/publr.js';
import { trapFocus } from '/static/scripts/publr-focus.js';

// Module-level bridge: the mounted instance's open() lands here (a local:
// store has no global handle). One picker exists per page.
let activeOpen = null;

Publr.store('media-picker', () => {
    const state = Publr.reactive({
        open: false,
        loading: false,
        emptyGrid: false,
        items: [],
        folders: [],
        tags: [],
        chips: [],
        hasFolders: false,
        hasTags: false,
        info: '',
        canSelect: false,
        uploading: false,
        uploadText: 'Upload',
    });

    let el = null;
    let resolvePick = null;
    let releaseTrap = null;
    let accept = '';
    let search = '';
    let folderId = '';
    let folderName = '';
    let tagIds = [];
    let tagNames = {};
    let selectedId = '';
    let pendingSelectId = null;
    let gen = 0; // request generation — drops stale (out-of-order) responses
    let searchTimer = null;
    let prevOverflow = null;
    let lastFocus = null;

    // Plain (non-reactive) records by id — pick() resolves with these, never
    // with a reactive proxy from state.items.
    const records = new Map();

    function syncChips() {
        const chips = [];
        if (folderId && folderName) chips.push({ key: 'folder', kind: 'folder', id: folderId, label: 'Folder:', text: folderName });
        tagIds.forEach((t) => chips.push({ key: 'tag:' + t, kind: 'tag', id: t, label: 'Tag:', text: tagNames[t] || t }));
        if (search) chips.push({ key: 'search', kind: 'search', id: '', label: 'Search:', text: search });
        state.chips = chips;
    }

    async function load() {
        const g = ++gen;
        state.loading = true;
        state.emptyGrid = false;
        state.canSelect = false;
        state.items = [];
        records.clear();
        syncChips();

        const params = new URLSearchParams();
        if (search) params.set('search', search);
        if (folderId) params.set('folder', folderId);
        tagIds.forEach((t) => params.append('tag', t));
        if (accept) params.set('accept', accept);
        const url = '/admin/media/picker/list' + (params.toString() ? '?' + params.toString() : '');

        try {
            const res = await fetch(url);
            const data = await res.json();
            if (g !== gen) return; // stale response — a newer request is in flight

            records.clear();
            (data.items || []).forEach((m) => records.set(m.id, m));
            if (pendingSelectId && records.has(pendingSelectId)) selectedId = pendingSelectId;
            pendingSelectId = null;
            if (selectedId && !records.has(selectedId)) selectedId = '';

            state.items = (data.items || []).map((m) => ({
                id: m.id,
                filename: m.filename || '',
                thumb_url: m.thumb_url || '',
                alt_text: m.alt_text || '',
                is_image: !!m.is_image,
                selected: m.id === selectedId,
            }));

            // Folder tree → flat ordered list with depth padding (hide empty
            // folders, keep the active one visible).
            const folders = (data.folders || []).filter((f) => f.count > 0 || f.id === folderId);
            const byParent = {};
            folders.forEach((f) => {
                const pid = f.parent_id || '';
                (byParent[pid] = byParent[pid] || []).push(f);
            });
            const flat = [];
            (function walk(pid, depth) {
                (byParent[pid] || []).forEach((f) => {
                    flat.push({ id: f.id, name: f.name, count: f.count, pad: depth * 1.25 + 'rem', active: f.id === folderId });
                    walk(f.id, depth + 1);
                });
            })('', 0);
            state.folders = flat;
            state.hasFolders = flat.length > 0;

            const tags = (data.tags || []).filter((t) => t.count > 0 || tagIds.includes(t.id));
            tags.forEach((t) => { if (tagIds.includes(t.id)) tagNames[t.id] = t.name; });
            state.tags = tags.map((t) => ({ id: t.id, name: t.name, count: t.count, active: tagIds.includes(t.id) }));
            state.hasTags = state.tags.length > 0;

            state.info = (data.items || []).length + ' items';
            state.emptyGrid = state.items.length === 0;
            state.canSelect = !!selectedId;
            syncChips(); // tag names may have arrived with this response
        } catch (err) {
            if (g !== gen) return;
            console.error('Failed to load media:', err);
            records.clear();
            state.items = [];
            state.folders = [];
            state.hasFolders = false;
            state.tags = [];
            state.hasTags = false;
            state.emptyGrid = true;
            state.info = '';
        } finally {
            if (g === gen) state.loading = false;
        }
    }

    function unlock() {
        if (releaseTrap) { releaseTrap(); releaseTrap = null; }
        if (prevOverflow !== null) { document.body.style.overflow = prevOverflow; prevOverflow = null; }
        if (lastFocus && typeof lastFocus.focus === 'function') { try { lastFocus.focus(); } catch (e) {} }
        lastFocus = null;
    }

    // Monotonic open-session counter: uploads and other async completions
    // check it so a closed-and-reopened picker isn't mutated by stragglers.
    let session = 0;

    // Every close path funnels here: resolve the pending promise (null =
    // cancel, record = pick) exactly once, then restore page state.
    function finish(record) {
        const resolve = resolvePick;
        resolvePick = null;
        session++;
        clearTimeout(searchTimer);
        state.open = false;
        unlock();
        if (resolve) resolve(record);
    }

    function pick(m) {
        finish({
            id: m.id,
            url: m.url || '',
            thumb_url: m.thumb_url || '',
            alt_text: m.alt_text || '',
            width: m.width ?? null,
            height: m.height ?? null,
            filename: m.filename || '',
        });
    }

    function openPicker(opts) {
        return new Promise((resolve) => {
            // A previous open (shouldn't happen — the picker is singular per
            // page) is fully closed first so its promise resolves as cancelled
            // and its trap/overflow/focus state is released, not leaked.
            if (resolvePick || state.open) finish(null);
            session++;
            resolvePick = resolve;
            accept = (opts && opts.accept) || '';
            search = '';
            folderId = '';
            folderName = '';
            tagIds = [];
            tagNames = {};
            selectedId = (opts && opts.selectedId) || '';
            pendingSelectId = null;
            lastFocus = document.activeElement;
            prevOverflow = document.body.style.overflow;
            document.body.style.overflow = 'hidden';
            state.canSelect = false;
            state.uploading = false;
            state.uploadText = 'Upload';
            state.open = true;

            const fileInput = el && el.querySelector('[data-publr-part="file"]');
            if (fileInput) fileInput.accept = accept;
            const searchInput = el && el.querySelector('[data-publr-part="search"]');
            if (searchInput) searchInput.value = '';
            const content = el && el.querySelector('[data-publr-part="content"]');
            if (content) releaseTrap = trapFocus(content);
            setTimeout(() => { if (searchInput && state.open) searchInput.focus(); }, 100);

            load();
        });
    }

    async function uploadFiles(files) {
        const s = session;
        const uploadFolderId = folderId; // freeze — a reopen must not retarget the batch
        const csrf = document.querySelector('input[name="_csrf"]')?.value ?? '';
        state.uploading = true;
        let lastId = null;
        try {
            for (let i = 0; i < files.length; i++) {
                if (s !== session) break; // picker closed/reopened — abandon the rest
                state.uploadText = files.length > 1 ? `Uploading ${i + 1}/${files.length}…` : 'Uploading…';
                const fd = new FormData();
                fd.append('action', 'media.upload_json');
                fd.append('_csrf', csrf);
                if (uploadFolderId && uploadFolderId !== 'default') fd.append('folder_id', uploadFolderId);
                fd.append('file', files[i], files[i].name);

                let m = null;
                if (window.cms && window.cms.requestBinary) {
                    // WASM browser preview: its fetch bridge can't carry
                    // FormData — serialize the multipart body ourselves.
                    const response = new Response(fd);
                    const ct = response.headers.get('Content-Type');
                    const buf = await response.arrayBuffer();
                    const res = await window.cms.requestBinary('POST', '/admin/action', new Uint8Array(buf), ct);
                    if (!res || (res.status && res.status >= 400)) throw new Error('HTTP ' + (res ? res.status : '?'));
                    try { m = typeof res.body === 'string' ? JSON.parse(res.body) : null; } catch (e) { m = null; }
                    if (!m || m.error) throw new Error((m && m.error) || 'upload_failed');
                } else {
                    const r = await fetch('/admin/action', { method: 'POST', body: fd });
                    m = await r.json().catch(() => null);
                    if (!r.ok || !m || m.error) throw new Error((m && m.error) || 'HTTP ' + r.status);
                }
                if (m && m.id) lastId = m.id;
            }
            // WASM preview persists on a timer; an explicit save keeps a
            // just-uploaded file from vanishing on early reload.
            if (lastId && window.cms && window.cms.save) { try { await window.cms.save(); } catch (e) {} }
        } catch (err) {
            window.publr.toast('Upload failed: ' + err.message, { variant: 'error' });
        } finally {
            if (s === session) {
                state.uploadText = 'Upload';
                state.uploading = false;
            }
        }
        if (lastId && s === session && state.open) {
            pendingSelectId = lastId; // pre-select once the refreshed grid renders it
            load();
        }
    }

    const actions = {
        close: () => finish(null),
        overlayClick: (d, ctx) => {
            if (ctx.event.target === ctx.el) finish(null);
        },
        searchInput: (d, ctx) => {
            const value = ctx.event.target.value;
            clearTimeout(searchTimer);
            searchTimer = setTimeout(() => {
                search = value.trim();
                load();
            }, 300);
        },
        clickFolder: (d) => {
            folderId = d.folderId || '';
            folderName = d.folderName || '';
            load();
        },
        clickTag: (d) => {
            const id = d.tagId;
            if (tagIds.includes(id)) {
                tagIds = tagIds.filter((t) => t !== id);
                delete tagNames[id];
            } else {
                tagIds.push(id);
                tagNames[id] = d.tagName;
            }
            load();
        },
        removeChip: (d) => {
            if (d.kind === 'folder') {
                folderId = '';
                folderName = '';
            } else if (d.kind === 'tag') {
                tagIds = tagIds.filter((t) => t !== d.id);
                delete tagNames[d.id];
            } else if (d.kind === 'search') {
                search = '';
                const searchInput = el && el.querySelector('[data-publr-part="search"]');
                if (searchInput) searchInput.value = '';
            }
            load();
        },
        selectItem: (d) => {
            selectedId = d.mediaId;
            state.items.forEach((i) => { i.selected = i.id === selectedId; });
            state.canSelect = records.has(selectedId);
        },
        pickItem: (d) => {
            const rec = records.get(d.mediaId);
            if (rec) pick(rec);
        },
        confirmSelect: () => {
            const rec = records.get(selectedId);
            if (rec) pick(rec);
        },
        filesChosen: (d, ctx) => {
            const input = ctx.event.target;
            const files = [...input.files];
            input.value = ''; // same-file re-selects must fire change again
            if (files.length) uploadFiles(files);
        },
    };

    return {
        state,
        actions,
        setup: ({ el: root }) => {
            el = root;
            activeOpen = openPicker;
            // Capture phase: embedded hosts (the block editor's canvas chrome)
            // stop keydown propagation at bubble time, so a bubble listener can
            // miss Escape. Closing also consumes the event so the page
            // underneath doesn't react to the same press.
            const onKeydown = (e) => {
                if (e.key === 'Escape' && state.open) {
                    e.preventDefault();
                    e.stopPropagation();
                    finish(null);
                }
            };
            document.addEventListener('keydown', onKeydown, true);
            return () => {
                document.removeEventListener('keydown', onKeydown, true);
                clearTimeout(searchTimer);
                gen++; // in-flight list responses must not touch the disposed instance
                session++;
                if (activeOpen === openPicker) activeOpen = null;
                if (resolvePick) { const r = resolvePick; resolvePick = null; r(null); }
                unlock();
                el = null;
            };
        },
    };
});

// Programmatic entry point for embedded tools (block editor media adapter)
// and the image-picker form fields. Resolves null when no picker is mounted
// (e.g. login/setup pages) or on cancel.
window.PublrAdmin = Object.assign(window.PublrAdmin || {}, {
    pickMedia: (opts) => (activeOpen ? activeOpen(opts || {}) : Promise.resolve(null)),
});
