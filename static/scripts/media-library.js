// Media library — selection, bulk actions, upload, and folder management
// (PublrJS store). The media List view (src/views/admin/media/list.zsx) is
// one local:media-library island.
//
// Reactive state drives the toolbar count, the select-all banner, and the
// drop-zone highlight; setup() keeps the irreducibly-DOM parts: syncing
// server-rendered checkboxes/cards, sessionStorage persistence, bulk form
// filling, upload progress (the indicator lives in the bottom bar OUTSIDE
// this island), and repositioning the ZSX-rendered inline folder editor.
//
// Actions wired from nested DS islands (dropdown items, portalled content)
// resolve back here: resolveRef walks up through stores that lack the key,
// following portal backlinks.

import { Publr } from '/static/scripts/publr.js';

const STORAGE_KEY = 'publr-media-selection';

// Current filter context (URL without page param) — a selection only
// survives navigation within the same filtered view.
function filterContext() {
    const params = new URLSearchParams(window.location.search);
    params.delete('page');
    return window.location.pathname + '?' + params.toString();
}

Publr.store('media-library', () => {
    const state = Publr.reactive({
        count: 0,
        anySelected: false,
        pages: false, // select-all across every page of the filtered set
        showBanner: false,
        dragover: false,
        tagCreateOpen: false, // sidebar "new tag" inline form
    });

    let el = null;
    const selectedIds = new Set();

    const $ = (id) => document.getElementById(id);
    const allCheckboxes = () =>
        el ? [...el.querySelectorAll('.media-checkbox, .table-checkbox[value]')] : [];

    function bannerData() {
        const banner = $('media-select-all-banner');
        const d = banner ? banner.dataset : {};
        return {
            filteredCount: parseInt(d.filteredCount, 10) || 0,
            itemsPerPage: parseInt(d.itemsPerPage, 10) || 25,
            activeFolder: d.activeFolder || '',
            searchTerm: d.searchTerm || '',
            showUnreviewed: d.showUnreviewed || '0',
        };
    }

    // ── Selection ─────────────────────────────────────────────────────────

    function save() {
        sessionStorage.setItem(STORAGE_KEY, JSON.stringify({
            ids: Array.from(selectedIds),
            selectAllPages: state.pages,
            context: filterContext(),
        }));
    }

    function restore() {
        const raw = sessionStorage.getItem(STORAGE_KEY);
        if (!raw) return;
        try {
            const data = JSON.parse(raw);
            if (data.context && data.context !== filterContext()) {
                sessionStorage.removeItem(STORAGE_KEY);
                return;
            }
            (data.ids || []).forEach((id) => selectedIds.add(id));
            if (data.selectAllPages) {
                state.pages = true;
                allCheckboxes().forEach((cb) => selectedIds.add(cb.value));
                save();
            }
        } catch (e) { /* ignore corrupt data */ }
    }

    // Sync the server-rendered DOM with the selection set and recompute
    // the reactive state the template binds to.
    function syncDom() {
        if (!el) return;
        const boxes = allCheckboxes();
        boxes.forEach((cb) => {
            if (state.pages) selectedIds.add(cb.value);
            cb.checked = selectedIds.has(cb.value);
        });

        const { filteredCount, itemsPerPage } = bannerData();
        const count = state.pages ? filteredCount : selectedIds.size;
        state.count = count;
        state.anySelected = count > 0;

        const allVisible = boxes.length > 0 && boxes.every((cb) => selectedIds.has(cb.value));
        const master = $('media-select-all');
        if (master) {
            master.checked = allVisible;
            master.indeterminate = selectedIds.size > 0 && !allVisible;
        }
        state.showBanner = allVisible && filteredCount > itemsPerPage;

        const bulkBtn = $('media-bulk-actions-btn');
        if (bulkBtn) bulkBtn.disabled = count === 0;

        el.querySelectorAll('.media-card').forEach((card) => {
            const selected = selectedIds.has(card.dataset.mediaId);
            card.classList.toggle('selected', selected);
            card.dataset.selected = selected ? 'true' : 'false';
        });
        el.querySelectorAll('.table-checkbox[value]').forEach((cb) => {
            const row = cb.closest('tr');
            if (row) {
                const selected = selectedIds.has(cb.value);
                row.classList.toggle('selected', selected);
                row.dataset.selected = selected ? 'true' : 'false';
            }
        });
    }

    // Fill a bulk form's hidden fields. Always resolve by document id — the
    // dialogs holding these forms may be portalled outside the island.
    function fillBulkForm(prefix) {
        const idsField = $(prefix + '-ids');
        const selectAllField = $(prefix + '-select-all');
        if (state.pages) {
            const { activeFolder, searchTerm, showUnreviewed } = bannerData();
            const params = new URLSearchParams(window.location.search);
            if (idsField) idsField.value = '';
            if (selectAllField) selectAllField.value = '1';
            const set = (name, value) => {
                const field = $(prefix + '-filter-' + name);
                if (field) field.value = value;
            };
            set('folder', activeFolder);
            set('search', searchTerm);
            set('unreviewed', showUnreviewed);
            // Year/month come from the URL — the banner never carried them,
            // so date-filtered "select all pages" used to target the
            // UNFILTERED set server-side.
            set('year', params.get('year') || '');
            set('month', params.get('month') || '');
            set('tags', params.getAll('tag').join(','));
        } else {
            if (idsField) idsField.value = Array.from(selectedIds).join(',');
            if (selectAllField) selectAllField.value = '';
        }
    }

    // ── Upload (progress indicator lives in the bottom bar, outside the
    //    island — imperative by document id, like the legacy code) ─────────

    let uploading = false;

    function startUpload(files, folderId) {
        if (!files || files.length === 0 || uploading || !el) return;
        const form = $('media-upload-form');
        const csrfField = form && form.querySelector('input[name="_csrf"]');
        if (!csrfField) return;
        uploading = true;

        const ui = {
            wrap: $('upload-progress'),
            bar: $('upload-progress-bar'),
            text: $('upload-progress-text'),
            defaultBtn: $('upload-default-btn'),
            hereBtn: $('upload-here-btn'),
        };
        const total = files.length;
        let done = 0;
        if (ui.wrap) ui.wrap.style.display = '';
        if (ui.defaultBtn) ui.defaultBtn.style.display = 'none';
        if (ui.hereBtn) ui.hereBtn.style.display = 'none';
        if (ui.text) ui.text.textContent = 'Uploading ' + total + ' file' + (total > 1 ? 's' : '') + '...';
        if (ui.bar) ui.bar.style.setProperty('--progress', '0%');

        function fail() {
            uploading = false;
            if (ui.text) ui.text.textContent = 'Upload failed. Please try again.';
        }

        function uploadNext(i) {
            if (i >= total) {
                // WASM: save DB then navigate; native: reload page.
                if (window.cms && window.cms.requestBinary) {
                    window.cms.save().then(() => window.navigate('/admin/media')).catch(fail);
                } else {
                    window.location.reload();
                }
                return;
            }
            const fd = new FormData();
            fd.append('_csrf', csrfField.value);
            fd.append('action', 'media.upload');
            fd.append('folder_id', folderId || '');
            fd.append('file', files[i]);

            // WASM browser preview: the fetch bridge can't carry FormData.
            if (window.cms && window.cms.requestBinary) {
                const response = new Response(fd);
                const ct = response.headers.get('Content-Type');
                response.arrayBuffer().then((buf) => {
                    return window.cms.requestBinary('POST', '/admin/action', new Uint8Array(buf), ct).then((res) => {
                        if (!res || (res.status && res.status >= 400)) { fail(); return; }
                        done++;
                        const overallPct = (done / total) * 100;
                        if (ui.bar) ui.bar.style.setProperty('--progress', overallPct + '%');
                        if (ui.text) ui.text.textContent = 'Uploading ' + done + '/' + total + ' — ' + Math.round(overallPct) + '%';
                        uploadNext(i + 1);
                    });
                }).catch(fail);
                return;
            }

            const xhr = new XMLHttpRequest();
            xhr.open('POST', '/admin/action', true);
            xhr.upload.addEventListener('progress', (e) => {
                if (e.lengthComputable) {
                    const filePct = (e.loaded / e.total) * 100;
                    const overallPct = ((done * 100) + filePct) / total;
                    if (ui.bar) ui.bar.style.setProperty('--progress', overallPct + '%');
                    if (ui.text) ui.text.textContent = 'Uploading ' + (done + 1) + '/' + total + ' — ' + Math.round(overallPct) + '%';
                }
            });
            xhr.addEventListener('load', () => {
                if (xhr.status >= 400) { fail(); return; }
                done++;
                uploadNext(i + 1);
            });
            xhr.addEventListener('error', fail);
            xhr.send(fd);
        }

        uploadNext(0);
    }

    function openFilePicker(folderId) {
        const folderField = $('upload-folder-id');
        const fileInput = $('media-file-input');
        if (folderField) folderField.value = folderId || '';
        if (fileInput) fileInput.click();
    }

    // ── Inline folder editor (form + insertion row are ZSX-rendered;
    //    the store only repositions and configures them) ──────────────────

    const part = (name) => (el ? el.querySelector('[data-publr-part="' + name + '"]') : null);

    function cancelFolderEdit() {
        if (!el) return;
        const home = part('folder-editor-home');
        const form = document.querySelector('form[data-publr-part="folder-editor"]');
        const newRow = part('folder-new-row');
        // Un-hide whichever row the editor had replaced
        el.querySelectorAll('.media-folder-row.folder-editing').forEach((row) => {
            row.classList.remove('folder-editing');
            ['.media-folder-link', '.media-folder-count', '.media-folder-controls'].forEach((sel) => {
                const piece = row.querySelector(sel);
                if (piece) piece.style.display = '';
            });
        });
        if (newRow) {
            newRow.classList.add('hidden');
            newRow.style.paddingLeft = '';
        }
        if (home && form) home.appendChild(form);
    }

    // mode: 'create' | 'rename' | 'move'
    function configureEditor(mode, opts) {
        const form = part('folder-editor');
        if (!form) return null;
        const q = (name) => form.querySelector('[data-publr-part="folder-editor-' + name + '"]');
        const action = q('action');
        const term = q('term');
        const parent = q('parent');
        const nameInput = q('name');
        const select = q('select');

        action.value = 'media.folder_' + mode;
        term.disabled = mode === 'create';
        term.value = opts.folderId || '';
        parent.disabled = !(mode === 'create' && opts.parentId);
        parent.value = opts.parentId || '';
        nameInput.disabled = mode === 'move';
        nameInput.classList.toggle('hidden', mode === 'move');
        nameInput.value = mode === 'rename' ? (opts.folderName || '') : '';
        select.disabled = mode !== 'move';
        select.classList.toggle('hidden', mode !== 'move');
        if (mode === 'move') {
            [...select.options].forEach((o) => {
                // depth >= max stays server-disabled; additionally exclude self
                if (!o.dataset.serverDisabled) o.disabled = false;
                if (o.value && o.value === opts.folderId) o.disabled = true;
            });
            select.value = '';
        }
        return form;
    }

    function focusEditor(form, mode) {
        const target = mode === 'move'
            ? form.querySelector('select:not([disabled])')
            : form.querySelector('input[type="text"]:not([disabled])');
        if (target) {
            target.focus();
            if (target.type === 'text' && target.value) target.select();
        }
    }

    function editInRow(row, mode, opts) {
        cancelFolderEdit();
        const form = configureEditor(mode, opts);
        if (!form || !row) return;
        row.classList.add('folder-editing');
        ['.media-folder-link', '.media-folder-count', '.media-folder-controls'].forEach((sel) => {
            const piece = row.querySelector(sel);
            if (piece) piece.style.display = 'none';
        });
        row.appendChild(form);
        focusEditor(form, mode);
    }

    function insertCreateRow(afterLi, parentId, depth) {
        cancelFolderEdit();
        const form = configureEditor('create', { parentId: parentId });
        const newRow = part('folder-new-row');
        if (!form || !newRow || !el) return;
        const slot = newRow.querySelector('[data-publr-part="folder-new-slot"]');
        slot.appendChild(form);
        newRow.classList.remove('hidden');
        newRow.style.paddingLeft = depth > 0 ? (0.5 + depth * 0.75) + 'rem' : '';

        const list = el.querySelector('.media-folder-list');
        if (afterLi) {
            // Insert after the parent and all its descendants
            const parentDepth = depth - 1;
            let insertBefore = afterLi.nextElementSibling;
            if (parentId) {
                while (insertBefore) {
                    const r = insertBefore.querySelector('.media-folder-row');
                    if (!r || !r.dataset.folderDepth) break;
                    const d = parseInt(r.dataset.folderDepth, 10);
                    if (isNaN(d) || d <= parentDepth) break;
                    insertBefore = insertBefore.nextElementSibling;
                }
            }
            afterLi.parentNode.insertBefore(newRow, insertBefore);
        } else if (list) {
            list.insertBefore(newRow, list.firstElementChild);
        }
        focusEditor(form, 'create');
    }

    // ── Actions ───────────────────────────────────────────────────────────

    const actions = {
        noop: () => {},
        toggleItem: (d, ctx) => {
            const cb = ctx.event.target;
            if (cb.checked) {
                selectedIds.add(cb.value);
            } else {
                selectedIds.delete(cb.value);
                state.pages = false;
            }
            save();
            syncDom();
        },
        toggleAll: (d, ctx) => {
            if (ctx.event.target.checked) {
                allCheckboxes().forEach((cb) => selectedIds.add(cb.value));
            } else {
                selectedIds.clear();
                state.pages = false;
            }
            save();
            syncDom();
        },
        selectAllPages: () => {
            state.pages = true;
            save();
            syncDom();
        },
        clearSelection: () => {
            state.pages = false;
            selectedIds.clear();
            save();
            syncDom();
        },
        bulkAction: (d) => {
            const action = d.bulkAction;
            const { filteredCount } = bannerData();
            const count = state.pages ? filteredCount : selectedIds.size;
            if (count === 0) return;
            if (action === 'delete') {
                if (!confirm('Delete ' + count + ' selected items permanently?')) return;
                fillBulkForm('bulk-delete');
                sessionStorage.removeItem(STORAGE_KEY);
                const form = $('bulk-delete-form');
                // requestSubmit in the WASM shell — its document-level submit
                // listener routes forms through the bridge; form.submit()
                // would bypass it.
                if (form) {
                    if (window.cms && form.requestSubmit) form.requestSubmit();
                    else form.submit();
                }
            } else if (action === 'add-tag' || action === 'remove-tag' || action === 'move-folder') {
                const prefix = 'bulk-' + action;
                fillBulkForm(prefix);
                const dialog = $(prefix + '-dialog');
                const trigger = dialog && dialog.querySelector('[data-publr-part="trigger"]');
                if (trigger) trigger.click();
            }
        },

        uploadDefault: () => openFilePicker(''),
        uploadHere: () => openFilePicker(bannerData().activeFolder),
        uploadFilesChosen: (d, ctx) => {
            const input = ctx.event.target;
            const files = [...input.files];
            const folderField = $('upload-folder-id');
            const folderId = folderField ? folderField.value : '';
            input.value = ''; // same-file re-selects must fire change again
            startUpload(files, folderId);
        },
        zoneOver: () => { state.dragover = true; },
        zoneLeave: () => { state.dragover = false; },
        zoneDrop: (d, ctx) => {
            state.dragover = false;
            startUpload([...ctx.event.dataTransfer.files], bannerData().activeFolder);
        },
        zoneClick: (d, ctx) => {
            if (ctx.event.target.closest('a')) return; // don't intercept links
            openFilePicker(bannerData().activeFolder);
        },

        toggleTagCreate: () => {
            state.tagCreateOpen = !state.tagCreateOpen;
            if (state.tagCreateOpen) {
                // Focus after the :showIf effect has unhidden the form.
                setTimeout(() => {
                    const input = document.querySelector('#tag-create-form input[type="text"]');
                    if (input) input.focus();
                }, 0);
            }
        },
        closeTagCreate: () => {
            state.tagCreateOpen = false;
            const trigger = part('tag-create-trigger');
            if (trigger) trigger.focus();
        },

        folderAction: (d, ctx) => {
            const action = d.publrAction;
            if (action === 'create-toplevel') {
                insertCreateRow(null, '', 0);
            } else if (action === 'create-subfolder') {
                const li = ctx.el.closest('.media-folder-item');
                const row = li ? li.querySelector('.media-folder-row') : null;
                const parentDepth = row && row.dataset.folderDepth ? parseInt(row.dataset.folderDepth, 10) : -1;
                insertCreateRow(li, d.parentId || '', parentDepth + 1);
            } else if (action === 'rename-folder' || action === 'move-folder') {
                const row = el && el.querySelector('.media-folder-row[data-folder-id="' + d.folderId + '"]');
                if (row) {
                    editInRow(row, action === 'rename-folder' ? 'rename' : 'move', {
                        folderId: d.folderId,
                        folderName: d.folderName,
                    });
                }
            } else if (action === 'delete-folder') {
                const deleteId = $('folder-delete-id');
                const trigger = document.querySelector('#folder-delete-dialog [data-publr-part="trigger"]');
                if (deleteId) deleteId.value = d.folderId;
                if (trigger) trigger.click();
            }
        },
        cancelFolderEdit: () => cancelFolderEdit(),
    };

    return {
        state,
        actions,
        setup: ({ el: root }) => {
            el = root;

            // Grid view: a checkbox click must not bubble into the card's
            // navigation. Capture phase so it beats the card handler.
            const onCaptureClick = (e) => {
                if (e.target.classList && e.target.classList.contains('media-checkbox')) {
                    e.stopPropagation();
                }
            };
            document.addEventListener('click', onCaptureClick, true);

            // Any bulk form submit consumes the persisted selection.
            const onSubmit = () => sessionStorage.removeItem(STORAGE_KEY);
            const forms = ['bulk-add-tag-form', 'bulk-remove-tag-form', 'bulk-move-folder-form']
                .map((id) => $(id))
                .filter(Boolean);
            forms.forEach((f) => f.addEventListener('submit', onSubmit));

            // Nested HMR (e.g. only MediaControls swapped) re-hydrates a
            // subtree without recreating this island — re-sync on the
            // bubbling publr:init the dev runtime dispatches after swaps.
            const onInit = () => syncDom();
            root.addEventListener('publr:init', onInit);

            // Mark server-disabled move options so mode switches don't
            // accidentally re-enable depth-capped folders.
            const select = part('folder-editor-select');
            if (select) {
                [...select.options].forEach((o) => { if (o.disabled) o.dataset.serverDisabled = '1'; });
            }

            restore();
            syncDom();

            return () => {
                document.removeEventListener('click', onCaptureClick, true);
                forms.forEach((f) => f.removeEventListener('submit', onSubmit));
                root.removeEventListener('publr:init', onInit);
                cancelFolderEdit();
                el = null;
            };
        },
    };
});
