// Entry editor — autosave, field-level change detection, publish/discard
// chrome, and release integration (PublrJS store). Island = the edit-layout
// split container in views/admin/layout_edit.zsx, which contains the entry
// form, the sidebar controls ([form="entry-form"]) and the release menu.
// setup() no-ops on pages without #entry-form (version history/compare share
// the layout).
//
// This is a lifecycle-managed port of the legacy admin.js section: the
// change-detection engine stays imperative against the server-rendered
// field DOM (reactive conversion is follow-up polish); the store gives it
// teardown, HMR re-init via publr:init, and declarative release actions
// (the legacy content-click binding broke when the DS dropdown started
// portalling its content to <body>).
//
// Server contracts:
//   * #entry-form dataset: entryId, entryStatus, baseUrl, publishedState
//     (JSON), fieldsInReleases (JSON), fieldEditors (JSON).
//   * Autosave: POST /admin/action (action=content.autosave, urlencoded)
//     → {"status":"draft"|"changed","saved":true[,"rejected_fields":
//     [{"field","owner"}]]}.
//   * Presence pushes publr:fields-updated / publr:published-state /
//     publr:release-updated CustomEvents on the form (static/presence.js).
//   * The block editor feeds a synthetic bubbling `input` event into the
//     form's hidden content input on every commit — the input/change
//     listeners below are its autosave path.

import { Publr } from '/static/scripts/publr.js';

// The vendored icon set has no eye / eye-off yet (DS gap) — inline SVGs.
const PEEK_ICON_SHOW = '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M2.42 12.71C2.28 12.5 2.22 12.39 2.18 12.22A.68.68 0 0 1 2.18 11.78C2.22 11.61 2.28 11.5 2.42 11.29 3.55 9.5 6.9 5 12 5s8.45 4.5 9.58 6.29c.14.21.21.32.24.49a.68.68 0 0 1 0 .44c-.04.17-.1.28-.24.49C20.45 14.5 17.1 19 12 19S3.55 14.5 2.42 12.71Z"/><circle cx="12" cy="12" r="3"/></svg>';
const PEEK_ICON_HIDE = '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M10.74 5.09C11.15 5.03 11.57 5 12 5c5.1 0 8.45 4.5 9.58 6.29.14.21.21.32.24.49a.68.68 0 0 1 0 .45c-.04.16-.1.28-.24.49-.3.47-.76 1.14-1.36 1.86M6.72 6.72A14.02 14.02 0 0 0 2.42 11.29c-.14.22-.21.33-.24.49a.68.68 0 0 0 0 .44c.04.17.1.28.24.49C3.55 14.5 6.9 19 12 19c2.06 0 3.83-.73 5.29-1.72M3 3l18 18M9.88 9.88A3 3 0 0 0 9 12a3 3 0 0 0 3 3 3 3 0 0 0 2.12-.88"/></svg>';

Publr.store('entry-editor', () => {
    let form = null;
    let entryId = '';
    let entryStatus = 'draft';
    let publishedFields = null;
    let fieldsInReleases = {};
    let lastSavedState = '';
    let saveTimer = null;
    let isSaving = false;
    let isDirty = false;
    let changedFieldCount = 0;
    let selectedFieldCount = 0;
    const cleanups = [];

    const $ = (id) => document.getElementById(id);
    const listen = (target, type, fn, opts) => {
        target.addEventListener(type, fn, opts);
        cleanups.push(() => target.removeEventListener(type, fn, opts));
    };

    // ── Server-state parsing ─────────────────────────────────────────────

    function parseFieldsInReleases(items) {
        const map = {};
        for (const item of items) {
            if (item.fields === null) continue;
            const entry = { id: item.id, name: item.name, scheduled_for: item.scheduled_for || null };
            for (const f of item.fields) {
                if (!map[f]) map[f] = [];
                if (!map[f].some((e) => e.id === item.id)) map[f].push(entry);
            }
        }
        return map;
    }

    // Sub-fields inside containers (repeaters, groups) are not independently tracked
    function isNestedField(node) {
        return node.closest('.field-repeater-item-content') !== null || node.closest('.field-group-content') !== null;
    }

    // ── Field chrome (badges, release links, wrappers, peek) ─────────────

    function renderEditorBadges(fieldEditors) {
        form.querySelectorAll('.field-editor-badge[data-field]').forEach((badge) => {
            if (isNestedField(badge)) return;
            const editor = fieldEditors[badge.dataset.field];
            if (!editor) return;
            // DOM construction — editor name/avatar are user-controlled.
            const img = document.createElement('img');
            img.src = editor.avatar;
            img.alt = '';
            img.className = 'field-editor-avatar h-5 w-5 shrink-0 rounded-full';
            const label = document.createElement('span');
            label.textContent = 'Edited by ' + editor.name;
            badge.replaceChildren(img, label);
            badge.classList.add('field-editor-active');
            // Disable the field and mark as hard-locked — the backend
            // preserves existing values for absent fields.
            const group = badge.closest('.form-group');
            if (group) {
                group.classList.add('field-hard-locked', 'opacity-60');
                group.querySelectorAll('input, textarea, select, button').forEach((node) => {
                    if (node.classList.contains('field-peek-btn')) return;
                    node.disabled = true;
                });
            }
        });
    }

    function renderReleaseLinks(group) {
        group.querySelectorAll('.field-release-link').forEach((l) => l.remove());
        const releases = fieldsInReleases[group.dataset.field];
        if (!releases || releases.length === 0) return;
        const container = group.querySelector('.field-check-row') || group.querySelector('.form-label-row');
        if (!container) return;
        for (const rel of releases) {
            const link = document.createElement('a');
            link.href = '/admin/releases/' + rel.id;
            link.className = 'field-release-link whitespace-nowrap text-xs text-primary no-underline hover:underline';
            link.textContent = 'In release: ' + rel.name;
            container.appendChild(link);
        }
    }

    // Set up .field-wrapper + peek button + "Changed" pill on all form
    // groups. Idempotent — re-run for dynamically added sub-fields.
    function initFieldWrappers() {
        form.querySelectorAll('.form-group[data-field]').forEach((group) => {
            const label = group.querySelector('.form-label-row .form-label') || group.querySelector('.form-label-row label');
            if (label && !label.querySelector('.field-changed-pill')) {
                const pill = document.createElement('span');
                pill.className = "field-changed-pill ml-2 hidden whitespace-nowrap rounded-full border border-warning px-2 py-px text-xs font-semibold leading-[1.4] text-warning [.form-group.field-changed_&]:inline-block";
                pill.textContent = 'Changed';
                label.appendChild(pill);
            }

            const control = group.querySelector('.form-control');
            const container = !control ? group.querySelector('.field-repeater, .field-group') : null;
            const target = control || container;
            if (!target || target.closest('.field-wrapper')) return;

            const wrapper = document.createElement('div');
            wrapper.className = 'field-wrapper relative rounded-[calc(var(--radius)*0.8)] outline outline-[3px] outline-transparent transition-[outline-color] [&.field-changed]:outline-warning [&.field-deselected]:outline-input [&.field-in-release]:outline-primary';
            target.parentNode.insertBefore(wrapper, target);
            wrapper.appendChild(target);

            // Peek button only for regular fields (not containers)
            if (control) {
                control.classList.add('pr-9');
                const btn = document.createElement('button');
                btn.type = 'button';
                btn.className = 'field-peek-btn absolute right-1.5 top-1/2 z-[1] hidden h-7 w-7 -translate-y-1/2 cursor-pointer items-center justify-center rounded-[calc(var(--radius)*0.6)] border-0 bg-transparent p-0 text-muted-foreground transition-colors hover:bg-accent hover:text-foreground [.field-wrapper.field-changed_&]:flex [.field-wrapper.field-deselected_&]:flex [.field-wrapper:has(textarea)_&]:top-3 [.field-wrapper:has(textarea)_&]:translate-y-0 [&_svg]:h-4 [&_svg]:w-4';
                btn.title = 'Show published value';
                btn.innerHTML = PEEK_ICON_SHOW;
                wrapper.appendChild(btn);

                const valueBox = document.createElement('div');
                valueBox.className = 'field-peek-value mt-1 flex max-h-[200px] gap-1 overflow-y-auto whitespace-pre-wrap break-words px-2 text-xs font-semibold text-muted-foreground';
                valueBox.style.display = 'none';
                wrapper.after(valueBox);

                btn.addEventListener('click', () => {
                    const vb = group.querySelector('.field-peek-value');
                    if (vb.style.display === 'none') {
                        vb.style.display = '';
                        btn.innerHTML = PEEK_ICON_HIDE;
                        btn.title = 'Hide published value';
                    } else {
                        vb.style.display = 'none';
                        btn.innerHTML = PEEK_ICON_SHOW;
                        btn.title = 'Show published value';
                    }
                });
            }
        });
    }

    function getFieldWrapper(group) {
        return group.querySelector('.field-wrapper');
    }

    function resetPeek(group) {
        if (!group) return;
        const vb = group.querySelector('.field-peek-value');
        if (vb) vb.style.display = 'none';
        const btn = group.querySelector('.field-peek-btn');
        if (btn) {
            btn.innerHTML = PEEK_ICON_SHOW;
            btn.title = 'Show published value';
        }
    }

    function updatePeek(group, publishedValue) {
        const vb = group.querySelector('.field-peek-value');
        if (!vb) return;
        const currentValue = getFieldValue(group.dataset.field);
        const row = document.createElement('div');
        row.className = 'field-peek-row flex min-w-0 items-baseline gap-2';
        const oldSpan = document.createElement('span');
        oldSpan.className = 'field-peek-old text-destructive';
        oldSpan.textContent = publishedValue === '' ? '(empty)' : publishedValue;
        const arrow = document.createElement('span');
        arrow.className = 'field-peek-arrow shrink-0 text-muted-foreground';
        arrow.textContent = '→';
        const newSpan = document.createElement('span');
        newSpan.className = 'field-peek-new text-success';
        newSpan.textContent = currentValue === '' ? '(empty)' : currentValue;
        row.append(oldSpan, arrow, newSpan);
        vb.replaceChildren(row);
    }

    // ── Form state / autosave ─────────────────────────────────────────────

    function getFormState() {
        const state = {};
        new FormData(form).forEach((value, key) => {
            if (key === '_csrf' || key === 'action' || key === 'release_id' || key === 'release_name' || key === 'status' || key === 'fields') return;
            state[key] = value;
        });
        return state;
    }

    function showStatus(type) {
        const statusEl = $('autosave-status');
        if (!statusEl) return;
        statusEl.className = 'autosave-status min-h-[1.125rem] text-center text-xs leading-[1.125rem]';
        if (type === 'saving') {
            statusEl.textContent = 'Saving...';
            statusEl.classList.add('autosave-status-saving', 'text-muted-foreground');
        } else if (type === 'saved') {
            statusEl.textContent = 'All changes saved';
            statusEl.classList.add('autosave-status-saved', 'text-success');
        } else if (type === 'error') {
            statusEl.textContent = 'Save failed';
            statusEl.classList.add('autosave-status-error', 'text-destructive');
        } else if (type === 'rejected') {
            statusEl.classList.add('autosave-status-rejected', 'text-warning');
        } else {
            statusEl.textContent = '';
        }
    }

    function onFormChange(e) {
        // field-publish checkbox toggles don't affect form content
        if (e && e.target && e.target.classList.contains('field-publish-check')) return;
        clearTimeout(saveTimer);
        isDirty = JSON.stringify(getFormState()) !== lastSavedState;
        updateButtons();
        if (isDirty) saveTimer = setTimeout(autoSave, 1500);
    }

    function autoSave() {
        const currentState = getFormState();
        const stateJson = JSON.stringify(currentState);
        if (stateJson === lastSavedState) return;
        if (isSaving) {
            saveTimer = setTimeout(autoSave, 500);
            return;
        }

        isSaving = true;
        const g = mountGen; // stale saves must not touch a remounted editor
        showStatus('saving');

        // Autosave goes through the action dispatcher: the form's hidden
        // `action` is content.update; override to content.autosave for this
        // request only.
        const autosaveData = new FormData(form);
        autosaveData.set('action', 'content.autosave');
        fetch('/admin/action', {
            method: 'POST',
            headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
            body: new URLSearchParams(autosaveData),
        })
            .then((r) => r.json())
            .then((data) => {
                isSaving = false;
                if (!form || g !== mountGen) return; // torn down / remounted mid-flight
                lastSavedState = stateJson;
                isDirty = false;

                if (data.status) {
                    entryStatus = data.status;
                    form.dataset.entryStatus = entryStatus;
                }

                if (data.rejected_fields && data.rejected_fields.length > 0) {
                    const names = data.rejected_fields.map((r) => r.field + ' (locked by ' + r.owner + ')');
                    showStatus('rejected');
                    const statusEl = $('autosave-status');
                    if (statusEl) statusEl.textContent = 'Rejected: ' + names.join(', ');
                } else {
                    showStatus('saved');
                }

                updateButtons();
            })
            .catch(() => {
                isSaving = false;
                if (!form || g !== mountGen) return;
                showStatus('error');
            });
    }

    // ── Field-level change detection ─────────────────────────────────────

    function getFieldValue(fieldKey) {
        const group = form.querySelector('.form-group[data-field="' + fieldKey + '"]');
        if (group) {
            const control = group.querySelector('.form-control');
            if (control) return control.value || '';
            const cb = group.querySelector('.form-check-input');
            if (cb) return cb.checked ? 'true' : 'false';
        }
        // Sidebar fields with form= attribute; posts name="content" for body
        const formName = fieldKey === 'body' ? 'content' : fieldKey;
        const node = document.querySelector('[name="' + fieldKey + '"][form="entry-form"]') ||
            document.querySelector('[name="' + formName + '"][form="entry-form"]');
        return node ? (node.value || '') : '';
    }

    function updateRepeaterPeeks(repeater, fieldKey, publishedArr, changed) {
        const published = Array.isArray(publishedArr) ? publishedArr : [];
        repeater.querySelectorAll('.field-repeater-item-content .form-group[data-field]').forEach((subGroup) => {
            if (!changed) { resetPeek(subGroup); return; }
            const subFieldKey = subGroup.dataset.field;
            if (subFieldKey.indexOf(fieldKey + '.') !== 0) return;
            const rest = subFieldKey.substring(fieldKey.length + 1);
            const dotPos = rest.indexOf('.');
            if (dotPos === -1) { resetPeek(subGroup); return; }
            const idx = parseInt(rest.substring(0, dotPos), 10);
            const subField = rest.substring(dotPos + 1);
            if (subField.indexOf('.') !== -1) { resetPeek(subGroup); return; }

            const pubItem = (idx < published.length && typeof published[idx] === 'object' && published[idx] !== null) ? published[idx] : null;
            const pubVal = pubItem ? ((pubItem[subField] != null) ? String(pubItem[subField]) : '') : '';
            const input = subGroup.querySelector('.form-control');
            const curVal = input ? (input.value || '') : '';

            if (curVal !== pubVal || pubItem === null) {
                updatePeek(subGroup, pubVal);
            } else {
                resetPeek(subGroup);
            }
        });
    }

    function isRepeaterChanged(repeater, fieldKey, publishedArr) {
        const countInput = repeater.querySelector('[data-repeater-count]');
        const count = countInput ? parseInt(countInput.value, 10) : 0;

        if (!Array.isArray(publishedArr)) return count > 0;
        if (count !== publishedArr.length) return true;

        for (let i = 0; i < count; i++) {
            let pubItem = publishedArr[i];
            if (typeof pubItem !== 'object' || pubItem === null) pubItem = {};
            const prefix = fieldKey + '.' + i + '.';
            const inputs = repeater.querySelectorAll('[name]');
            for (const input of inputs) {
                if (input.hasAttribute('data-repeater-count')) continue;
                const name = input.name;
                if (name.indexOf(prefix) !== 0) continue;
                const subField = name.substring(prefix.length);
                if (subField.indexOf('.') !== -1) continue; // nested containers
                const pubVal = (pubItem[subField] != null) ? String(pubItem[subField]) : '';
                const curVal = input.type === 'checkbox' ? (input.checked ? 'true' : 'false') : (input.value || '');
                if (curVal !== pubVal) return true;
            }
        }
        return false;
    }

    function detectChangedFields() {
        if (!publishedFields || entryStatus === 'draft') {
            changedFieldCount = 0;
            selectedFieldCount = 0;
            form.querySelectorAll('.field-wrapper').forEach((w) => {
                w.classList.remove('field-changed', 'field-deselected', 'field-in-release');
                const g = w.closest('.form-group');
                if (g) g.classList.remove('field-changed', 'field-deselected', 'field-in-release');
                resetPeek(g);
            });
            return;
        }

        changedFieldCount = 0;
        selectedFieldCount = 0;

        form.querySelectorAll('.form-group[data-field]').forEach((group) => {
            if (isNestedField(group)) return;
            const fieldKey = group.dataset.field;
            const checkbox = group.querySelector('.field-publish-check');
            const wrapper = getFieldWrapper(group);

            let isChanged;
            let isContainer = false;
            const repeater = group.querySelector('.field-repeater[data-field]');
            let publishedValue;
            if (repeater) {
                isContainer = true;
                isChanged = isRepeaterChanged(repeater, fieldKey, publishedFields[fieldKey]);
            } else {
                const currentValue = getFieldValue(fieldKey);
                publishedValue = (publishedFields[fieldKey] != null) ? String(publishedFields[fieldKey]) : '';
                isChanged = currentValue !== publishedValue;
            }

            if (fieldsInReleases[fieldKey]) {
                if (wrapper) wrapper.classList.add('field-in-release');
                group.classList.add('field-in-release');
            } else {
                if (wrapper) wrapper.classList.remove('field-in-release');
                group.classList.remove('field-in-release');
            }

            if (isChanged) {
                changedFieldCount++;
                if (!isContainer) updatePeek(group, publishedValue);
                if (repeater) updateRepeaterPeeks(repeater, fieldKey, publishedFields[fieldKey], true);
                if (checkbox && checkbox.checked) {
                    if (wrapper) {
                        wrapper.classList.add('field-changed');
                        wrapper.classList.remove('field-deselected');
                    }
                    group.classList.add('field-changed');
                    selectedFieldCount++;
                } else if (checkbox) {
                    if (wrapper) {
                        wrapper.classList.remove('field-changed');
                        wrapper.classList.add('field-deselected');
                    }
                    group.classList.remove('field-changed');
                    group.classList.add('field-deselected');
                }
            } else {
                if (checkbox) checkbox.checked = true;
                if (wrapper) wrapper.classList.remove('field-changed', 'field-deselected');
                group.classList.remove('field-changed', 'field-deselected');
                if (!isContainer) resetPeek(group);
                if (repeater) updateRepeaterPeeks(repeater, fieldKey, publishedFields[fieldKey], false);
            }
        });
    }

    // ── Chrome sync (publish / discard / release trigger) ────────────────

    function updateButtons() {
        initFieldWrappers(); // new dynamic sub-fields need wrappers
        detectChangedFields();

        const publishBtn = $('publish-btn');
        if (publishBtn) {
            if (entryStatus === 'draft') {
                publishBtn.textContent = 'Publish';
                publishBtn.disabled = false;
            } else if (entryStatus === 'published' && !isDirty) {
                publishBtn.textContent = 'Published';
                publishBtn.disabled = true;
            } else if (changedFieldCount > 0 && selectedFieldCount === 0) {
                publishBtn.textContent = 'Publish Changes';
                publishBtn.disabled = true;
            } else if (changedFieldCount > 0 && selectedFieldCount < changedFieldCount) {
                publishBtn.textContent = 'Publish ' + selectedFieldCount + '/' + changedFieldCount;
                publishBtn.disabled = false;
            } else {
                publishBtn.textContent = 'Publish Changes';
                publishBtn.disabled = false;
            }
        }

        const discardBtn = $('discard-btn');
        if (discardBtn) {
            if (entryStatus === 'changed' || (entryStatus === 'published' && isDirty)) {
                discardBtn.classList.remove('hidden');
            } else {
                discardBtn.classList.add('hidden');
            }
        }

        // Imperative: a :disabled bind on the as_child dropdown trigger
        // would collide with its slotted data-p-bind (aria-expanded).
        const releaseDropdown = $('release-dropdown');
        const releaseTrigger = releaseDropdown && releaseDropdown.querySelector('[data-publr-part="trigger"]');
        if (releaseTrigger) {
            releaseTrigger.disabled = !entryId || (entryStatus === 'published' && !isDirty);
        }

        const releaseTriggerText = $('release-trigger-text');
        if (releaseTriggerText) {
            if (changedFieldCount > 0 && selectedFieldCount < changedFieldCount && selectedFieldCount > 0) {
                releaseTriggerText.textContent = 'Add ' + selectedFieldCount + '/' + changedFieldCount + ' to Release';
            } else {
                releaseTriggerText.textContent = 'Add to Release';
            }
        }
    }

    // ── Release / publish submit plumbing ─────────────────────────────────

    function populateFields() {
        const publishFieldsInput = $('publish-fields');
        if (!publishFieldsInput) return;
        if (changedFieldCount > 0 && selectedFieldCount < changedFieldCount) {
            const selected = [];
            form.querySelectorAll('.field-publish-check:checked').forEach((cb) => {
                const group = cb.closest('.form-group[data-field]');
                if (group) {
                    const w = getFieldWrapper(group);
                    if (w && w.classList.contains('field-changed')) {
                        selected.push(group.dataset.field);
                    }
                }
            });
            publishFieldsInput.value = selected.length > 0 ? JSON.stringify(selected) : '';
        } else {
            publishFieldsInput.value = '';
        }
    }

    // Programmatic submits: the WASM browser shell routes forms through a
    // document-level `submit` listener, which form.submit() bypasses — use
    // requestSubmit() there. Native keeps submit() (no constraint validation,
    // matching the legacy behavior).
    let programmaticSubmit = false;
    function submitForm(f) {
        if (window.cms && f.requestSubmit) {
            programmaticSubmit = true;
            try { f.requestSubmit(); } finally { programmaticSubmit = false; }
        } else {
            f.submit();
        }
    }

    function submitReleaseAction(action, releaseId, releaseName) {
        const releaseAction = $('release-action');
        const releaseIdField = $('release-id');
        const releaseNameField = $('release-name');
        if (!releaseAction || !releaseIdField || !releaseNameField) return;
        releaseAction.value = action;
        releaseIdField.value = releaseId || '';
        releaseNameField.value = releaseName || '';
        populateFields();
        submitForm(form);
    }

    function onFormSubmit(e) {
        populateFields();
        // Release submits already confirmed their intent; the pending-release
        // warning below is for the Publish button path only (form.submit()
        // never fired this handler in the legacy code).
        if (programmaticSubmit) return;
        // Warn when publishing fields that are also in pending releases
        const warnings = [];
        form.querySelectorAll('.form-group[data-field]').forEach((group) => {
            if (isNestedField(group)) return;
            const wrapper = getFieldWrapper(group);
            if (!wrapper || !wrapper.classList.contains('field-changed')) return;
            const releases = fieldsInReleases[group.dataset.field];
            if (!releases) return;
            for (const rel of releases) {
                if (!warnings.some((w) => w.id === rel.id)) warnings.push(rel);
            }
        });
        if (warnings.length > 0) {
            const names = warnings.map((w) => '"' + w.name + '"').join(', ');
            if (!confirm('Some fields you are publishing are also in pending release(s): ' + names + '.\n\nThis may cause conflicts when those releases are published later.\n\nContinue?')) {
                e.preventDefault();
                return false;
            }
        }
    }

    function discard() {
        if (!confirm('Discard all changes and revert to the published version?')) return;
        const csrfField = form.querySelector('input[name="_csrf"]');
        const typeField = form.querySelector('input[name="type"]');
        const discardForm = document.createElement('form');
        discardForm.method = 'POST';
        discardForm.action = '/admin/action';
        const add = (name, value) => {
            const input = document.createElement('input');
            input.type = 'hidden';
            input.name = name;
            input.value = value;
            discardForm.appendChild(input);
        };
        add('_csrf', csrfField ? csrfField.value : '');
        add('action', 'content.discard');
        add('type', typeField ? typeField.value : '');
        add('entry_id', entryId);
        document.body.appendChild(discardForm);
        submitForm(discardForm);
    }

    // ── Store surface ─────────────────────────────────────────────────────

    const actions = {
        addToRelease: (d, ctx) => {
            ctx.event.preventDefault();
            if (d.releaseId) submitReleaseAction('add_to_release', d.releaseId, '');
        },
        createRelease: (d, ctx) => {
            ctx.event.preventDefault();
            const nameInput = $('release-name-input');
            const name = nameInput ? nameInput.value.trim() : '';
            if (!name) return;
            submitReleaseAction('create_release', '', name);
        },
    };

    // ── Mount / unmount ──────────────────────────────────────────────────
    // Nested HMR can replace #entry-form (or the sidebar) WITHOUT recreating
    // this island, so form wiring is a separate mount that can be redone.

    let mountGen = 0;
    const boundExternals = [];

    // Idempotent per node — a sidebar HMR swap replaces external controls
    // without changing the form's identity. Markers are cleared on unmount
    // (listeners are removed there, so survivors must be rebindable).
    function bindExternal(node) {
        if (node.__publrEntryEditorBound) return;
        node.__publrEntryEditorBound = true;
        boundExternals.push(node);
        listen(node, 'input', onFormChange);
        listen(node, 'change', onFormChange);
    }
    function bindExternals() {
        document.querySelectorAll('[form="entry-form"]').forEach(bindExternal);
        const discardBtn = $('discard-btn');
        if (discardBtn && entryId && !discardBtn.__publrEntryEditorBound) {
            discardBtn.__publrEntryEditorBound = true;
            boundExternals.push(discardBtn);
            listen(discardBtn, 'click', discard);
        }
    }

    function mountForm() {
        form = document.getElementById('entry-form');
        if (!form) { form = null; return; }
        mountGen++;

        entryId = form.dataset.entryId || '';
        entryStatus = form.dataset.entryStatus || 'draft';

        publishedFields = null;
        try {
            if (form.dataset.publishedState) publishedFields = JSON.parse(form.dataset.publishedState);
        } catch (e) {}
        try {
            fieldsInReleases = parseFieldsInReleases(JSON.parse(form.dataset.fieldsInReleases || '[]'));
        } catch (e) { fieldsInReleases = {}; }
        let fieldEditors = {};
        try {
            fieldEditors = JSON.parse(form.dataset.fieldEditors || '{}');
        } catch (e) {}

        renderEditorBadges(fieldEditors);
        form.querySelectorAll('.form-group[data-field]').forEach((group) => {
            if (!isNestedField(group)) renderReleaseLinks(group);
        });
        initFieldWrappers();

        lastSavedState = JSON.stringify(getFormState());
        isDirty = false;
        updateButtons();

        // Change detection — the block editor's synthetic input events on
        // the hidden content input arrive through these listeners.
        listen(form, 'input', onFormChange);
        listen(form, 'change', onFormChange);
        listen(form, 'change', (e) => {
            if (e.target.classList.contains('field-publish-check')) updateButtons();
        });
        bindExternals();

        // Presence events: update UI state without triggering autosave
        listen(form, 'publr:fields-updated', () => updateButtons());
        listen(form, 'publr:published-state', (e) => {
            if (!e.detail) return;
            if (e.detail.publishedState) publishedFields = e.detail.publishedState;
            if (e.detail.status) {
                entryStatus = e.detail.status;
                form.dataset.entryStatus = entryStatus;
            }
            // Re-baseline so autosave detects changes against the new state
            lastSavedState = JSON.stringify(getFormState());
            isDirty = false;
            updateButtons();
        });
        listen(form, 'publr:release-updated', (e) => {
            if (!e.detail || !e.detail.fieldsInReleases) return;
            fieldsInReleases = parseFieldsInReleases(e.detail.fieldsInReleases);
            form.querySelectorAll('.form-group[data-field]').forEach((group) => {
                if (!isNestedField(group)) renderReleaseLinks(group);
            });
            updateButtons();
        });

        listen(form, 'submit', onFormSubmit);
    }

    function unmountForm() {
        clearTimeout(saveTimer);
        mountGen++; // in-flight autosaves must not touch the next mount
        cleanups.splice(0).forEach((fn) => fn());
        boundExternals.splice(0).forEach((node) => { delete node.__publrEntryEditorBound; });
        form = null;
        publishedFields = null;
        fieldsInReleases = {};
        isSaving = false;
        isDirty = false;
    }

    return {
        actions,
        setup: ({ el: root }) => {
            mountForm();

            // Nested HMR: a swapped-in #entry-form needs a full remount (the
            // old one is detached with our listeners); a same-form swap only
            // needs re-wrapping, external rebinding, and a state re-sync.
            const onInit = () => {
                const current = document.getElementById('entry-form');
                if (current !== form) {
                    unmountForm();
                    mountForm();
                } else if (form) {
                    bindExternals();
                    updateButtons();
                }
            };
            root.addEventListener('publr:init', onInit);

            return () => {
                root.removeEventListener('publr:init', onInit);
                unmountForm();
            };
        },
    };
});
