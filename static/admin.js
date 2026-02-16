// Publr Admin — Component Handlers
// Admin-specific wiring. Depends on interact modules (core, toggle, portal, focus-trap, dismiss).
// Component handlers are registered here; tasks 03-06 add the implementations.
(function() {
    'use strict';

    // ── Media Upload ─────────────────────────────────────
    var fileInput = document.getElementById('media-file-input');
    var form = document.getElementById('media-upload-form');
    if (fileInput && form) {
        var folderIdField = document.getElementById('upload-folder-id');
        var progressWrap = document.getElementById('upload-progress');
        var progressBar = document.getElementById('upload-progress-bar');
        var progressText = document.getElementById('upload-progress-text');
        var uploadDefaultBtn = document.getElementById('upload-default-btn');
        var uploadHereBtn = document.getElementById('upload-here-btn');
        var bottomBar = document.querySelector('.media-bottom-bar');
        var activeFolder = bottomBar ? bottomBar.dataset.activeFolder : '';

        // Upload to default folder
        if (uploadDefaultBtn) {
            uploadDefaultBtn.addEventListener('click', function() {
                if (folderIdField) folderIdField.value = '';
                fileInput.click();
            });
        }

        // Upload to current folder
        if (uploadHereBtn) {
            uploadHereBtn.addEventListener('click', function() {
                if (folderIdField) folderIdField.value = activeFolder;
                fileInput.click();
            });
        }

        function uploadFiles(files, folderId) {
            if (!files || files.length === 0) return;

            var csrf = form.querySelector('input[name="_csrf"]').value;
            var done = 0;
            var total = files.length;

            // Show progress, hide buttons
            if (progressWrap) progressWrap.style.display = '';
            if (uploadDefaultBtn) uploadDefaultBtn.style.display = 'none';
            if (uploadHereBtn) uploadHereBtn.style.display = 'none';
            progressText.textContent = 'Uploading ' + total + ' file' + (total > 1 ? 's' : '') + '...';
            progressBar.style.setProperty('--progress', '0%');

            function uploadNext(i) {
                if (i >= total) {
                    // WASM: save DB then navigate, Native: reload page
                    if (window.cms && window.cms.requestBinary) {
                        window.cms.save().then(function() {
                            window.navigate('/admin/media');
                        });
                    } else {
                        window.location.reload();
                    }
                    return;
                }
                var fd = new FormData();
                fd.append('_csrf', csrf);
                fd.append('folder_id', folderId || '');
                fd.append('file', files[i]);

                // WASM browser preview: use cms.requestBinary instead of XHR
                if (window.cms && window.cms.requestBinary) {
                    var response = new Response(fd);
                    var ct = response.headers.get('Content-Type');
                    response.arrayBuffer().then(function(buf) {
                        var bodyBytes = new Uint8Array(buf);
                        window.cms.requestBinary('POST', '/admin/media', bodyBytes, ct).then(function() {
                            done++;
                            var overallPct = (done / total) * 100;
                            progressBar.style.setProperty('--progress', overallPct + '%');
                            progressText.textContent = 'Uploading ' + done + '/' + total + ' — ' + Math.round(overallPct) + '%';
                            uploadNext(i + 1);
                        }).catch(function() {
                            progressText.textContent = 'Upload failed. Please try again.';
                        });
                    });
                    return;
                }

                var xhr = new XMLHttpRequest();
                xhr.open('POST', '/admin/media', true);

                xhr.upload.addEventListener('progress', function(e) {
                    if (e.lengthComputable) {
                        var filePct = (e.loaded / e.total) * 100;
                        var overallPct = ((done * 100) + filePct) / total;
                        progressBar.style.setProperty('--progress', overallPct + '%');
                        progressText.textContent = 'Uploading ' + (done + 1) + '/' + total + ' — ' + Math.round(overallPct) + '%';
                    }
                });

                xhr.addEventListener('load', function() {
                    done++;
                    uploadNext(i + 1);
                });

                xhr.addEventListener('error', function() {
                    progressText.textContent = 'Upload failed. Please try again.';
                });

                xhr.send(fd);
            }

            uploadNext(0);
        }

        // File input change (triggered by button clicks)
        fileInput.addEventListener('change', function() {
            var folderId = folderIdField ? folderIdField.value : '';
            uploadFiles(fileInput.files, folderId);
        });

        // Prevent form from submitting normally
        form.addEventListener('submit', function(e) {
            e.preventDefault();
        });

        // Drag and drop on empty state drop zone
        var zone = document.getElementById('media-upload-zone');
        if (zone) {
            zone.addEventListener('dragover', function(e) {
                e.preventDefault();
                zone.classList.add('dragover');
            });

            zone.addEventListener('dragleave', function(e) {
                e.preventDefault();
                zone.classList.remove('dragover');
            });

            zone.addEventListener('drop', function(e) {
                e.preventDefault();
                zone.classList.remove('dragover');
                uploadFiles(e.dataTransfer.files, activeFolder);
            });

            // Clicking the empty state also opens file picker
            zone.addEventListener('click', function(e) {
                if (e.target.closest('a')) return; // Don't intercept links
                if (folderIdField) folderIdField.value = activeFolder;
                fileInput.click();
            });
        }
    }

    // ── Folder Management ────────────────────────────
    var csrfEl = document.querySelector('input[name="_csrf"]');
    var csrfValue = csrfEl ? csrfEl.value : '';

    function cancelInlineForm() {
        // Remove inline-replace forms (rename, move)
        var existing = document.querySelector('.media-folder-inline-form');
        if (existing) {
            var row = existing.closest('.media-folder-row');
            existing.remove();
            if (row) {
                var link = row.querySelector('.media-folder-link');
                var count = row.querySelector('.media-folder-count');
                var controls = row.querySelector('.media-folder-controls');
                if (link) link.style.display = '';
                if (count) count.style.display = '';
                if (controls) controls.style.display = '';
            }
        }
        // Remove inserted new-folder rows
        var newRow = document.querySelector('.media-folder-new-row');
        if (newRow) newRow.remove();
    }

    function showInlineForm(row, action, fields) {
        cancelInlineForm();
        var link = row.querySelector('.media-folder-link');
        var count = row.querySelector('.media-folder-count');
        var controls = row.querySelector('.media-folder-controls');
        if (link) link.style.display = 'none';
        if (count) count.style.display = 'none';
        if (controls) controls.style.display = 'none';

        var form = document.createElement('form');
        form.method = 'POST';
        form.action = action;
        form.className = 'media-folder-inline-form';

        var csrf = document.createElement('input');
        csrf.type = 'hidden';
        csrf.name = '_csrf';
        csrf.value = csrfValue;
        form.appendChild(csrf);

        // Clone folder icon for visual consistency
        var icon = link ? link.querySelector('.icon') : null;
        if (icon) form.appendChild(icon.cloneNode(true));

        var focusTarget = null;
        for (var i = 0; i < fields.length; i++) {
            var f = fields[i];
            if (f.type === 'hidden') {
                var h = document.createElement('input');
                h.type = 'hidden';
                h.name = f.name;
                h.value = f.value;
                form.appendChild(h);
            } else if (f.type === 'text') {
                var t = document.createElement('input');
                t.type = 'text';
                t.name = f.name;
                t.value = f.value || '';
                t.placeholder = f.placeholder || '';
                t.className = 'form-control form-control-sm';
                form.appendChild(t);
                if (!focusTarget) focusTarget = t;
            } else if (f.type === 'select') {
                var s = document.createElement('select');
                s.name = f.name;
                s.className = 'form-control form-control-sm';
                for (var j = 0; j < f.options.length; j++) {
                    var o = document.createElement('option');
                    o.value = f.options[j].value;
                    o.textContent = f.options[j].label;
                    o.disabled = f.options[j].disabled || false;
                    s.appendChild(o);
                }
                form.appendChild(s);
                if (!focusTarget) focusTarget = s;
            }
        }

        var submit = document.createElement('button');
        submit.type = 'submit';
        submit.className = 'btn-icon-sm btn-icon-confirm';
        submit.textContent = '\u2713';
        submit.setAttribute('aria-label', 'Confirm');
        form.appendChild(submit);

        row.appendChild(form);
        if (focusTarget) {
            focusTarget.focus();
            if (focusTarget.type === 'text' && focusTarget.value) focusTarget.select();
        }
        form.addEventListener('keydown', function(e) {
            if (e.key === 'Escape') cancelInlineForm();
        });
    }

    function insertFolderForm(afterLi, parentId, depth) {
        cancelInlineForm();

        var li = document.createElement('li');
        li.className = 'media-folder-item media-folder-new-row';
        if (depth > 0) li.style.paddingLeft = (0.5 + depth * 0.75) + 'rem';

        var row = document.createElement('div');
        row.className = 'media-folder-row';

        var form = document.createElement('form');
        form.method = 'POST';
        form.action = '/admin/media/folders';
        form.className = 'media-folder-inline-form';

        var csrf = document.createElement('input');
        csrf.type = 'hidden';
        csrf.name = '_csrf';
        csrf.value = csrfValue;
        form.appendChild(csrf);

        if (parentId) {
            var pid = document.createElement('input');
            pid.type = 'hidden';
            pid.name = 'parent_id';
            pid.value = parentId;
            form.appendChild(pid);
        }

        // Clone folder icon from an existing folder link
        var icon = document.querySelector('.media-folder-link .icon');
        if (icon) form.appendChild(icon.cloneNode(true));

        var input = document.createElement('input');
        input.type = 'text';
        input.name = 'folder_name';
        input.placeholder = 'Folder name...';
        input.className = 'form-control form-control-sm';
        form.appendChild(input);

        var submit = document.createElement('button');
        submit.type = 'submit';
        submit.className = 'btn-icon-sm btn-icon-confirm';
        submit.textContent = '\u2713';
        submit.setAttribute('aria-label', 'Create folder');
        form.appendChild(submit);

        row.appendChild(form);
        li.appendChild(row);

        var list = document.querySelector('.media-folder-list');
        if (afterLi) {
            // Insert after parent and all its descendants
            var parentDepth = depth - 1;
            var insertBefore = afterLi.nextElementSibling;
            if (parentId) {
                while (insertBefore) {
                    var r = insertBefore.querySelector('.media-folder-row');
                    if (!r || !r.dataset.folderDepth) break;
                    var d = parseInt(r.dataset.folderDepth, 10);
                    if (isNaN(d) || d <= parentDepth) break;
                    insertBefore = insertBefore.nextElementSibling;
                }
            }
            afterLi.parentNode.insertBefore(li, insertBefore);
        } else if (list) {
            // Prepend at the top of the list (before Default)
            list.insertBefore(li, list.firstElementChild);
        }

        input.focus();
        form.addEventListener('keydown', function(e) {
            if (e.key === 'Escape') cancelInlineForm();
        });
    }

    var maxFolderDepth = 5;

    function buildFolderOptions(excludeId) {
        var options = [{ value: '', label: 'Top level' }];
        document.querySelectorAll('.media-folder-row[data-folder-id]').forEach(function(row) {
            var depth = parseInt(row.dataset.folderDepth, 10) || 0;
            var prefix = '';
            for (var d = 0; d < depth; d++) prefix += '\u2014 ';
            options.push({
                value: row.dataset.folderId,
                label: prefix + row.dataset.folderName,
                disabled: row.dataset.folderId === excludeId || depth >= maxFolderDepth
            });
        });
        return options;
    }

    document.addEventListener('click', function(e) {
        var btn = e.target.closest('[data-publr-action]');
        if (!btn) return;
        var action = btn.dataset.publrAction;

        if (action === 'create-toplevel') {
            insertFolderForm(null, '', 0);
        } else if (action === 'create-subfolder') {
            var li = btn.closest('.media-folder-item');
            var row = li ? li.querySelector('.media-folder-row') : null;
            var parentDepth = row && row.dataset.folderDepth ? parseInt(row.dataset.folderDepth, 10) : -1;
            if (li) insertFolderForm(li, btn.dataset.parentId, parentDepth + 1);
        } else if (action === 'rename-folder') {
            var row = btn.closest('.media-folder-row') ||
                document.querySelector('.media-folder-row[data-folder-id="' + btn.dataset.folderId + '"]');
            if (row) showInlineForm(row, '/admin/media/folders/rename', [
                { type: 'hidden', name: 'term_id', value: btn.dataset.folderId },
                { type: 'text', name: 'folder_name', value: btn.dataset.folderName, placeholder: 'Folder name...' }
            ]);
        } else if (action === 'move-folder') {
            var row = btn.closest('.media-folder-row') ||
                document.querySelector('.media-folder-row[data-folder-id="' + btn.dataset.folderId + '"]');
            if (row) showInlineForm(row, '/admin/media/folders/move', [
                { type: 'hidden', name: 'term_id', value: btn.dataset.folderId },
                { type: 'select', name: 'parent_id', options: buildFolderOptions(btn.dataset.folderId) }
            ]);
        } else if (action === 'delete-folder') {
            var deleteId = document.getElementById('folder-delete-id');
            var trigger = document.querySelector('#folder-delete-dialog [data-publr-part="trigger"]');
            if (deleteId) deleteId.value = btn.dataset.folderId;
            if (trigger) trigger.click();
        }
    });

})();

// ── Version Compare ──────────────────────────────
(function() {
    'use strict';
    var toggle = document.getElementById('show-diff-only');
    var fields = document.getElementById('version-compare-fields');
    var applyBtn = document.getElementById('apply-changes-btn');
    if (!fields) return;

    function updateApplyBtn() {
        if (!applyBtn) return;
        var hasOld = document.querySelector('.version-compare-cell-old input[type="radio"]:checked') !== null;
        applyBtn.disabled = !hasOld;
    }

    if (toggle) {
        toggle.addEventListener('change', function() {
            fields.classList.toggle('show-diff-only', toggle.checked);
        });
    }

    var selectAll = document.getElementById('select-all-old');
    if (selectAll) {
        selectAll.addEventListener('click', function(e) {
            e.preventDefault();
            document.querySelectorAll('.version-compare-cell-old input[type="radio"]:not(:disabled)').forEach(function(r) {
                r.checked = true;
            });
            updateApplyBtn();
        });
    }

    fields.addEventListener('change', function(e) {
        if (e.target.type === 'radio') updateApplyBtn();
    });
})();

// ── Post Edit: Auto-save + Release Integration ──
(function() {
    'use strict';
    var form = document.getElementById('entry-form');
    if (!form) return;

    var publishBtn = document.getElementById('publish-btn');
    var discardBtn = document.getElementById('discard-btn');
    var statusEl = document.getElementById('autosave-status');
    var releaseDropdown = document.getElementById('release-dropdown');
    var releaseTrigger = releaseDropdown ? releaseDropdown.querySelector('[data-publr-part="trigger"]') : null;
    var releaseAction = document.getElementById('release-action');
    var releaseIdField = document.getElementById('release-id');
    var releaseNameField = document.getElementById('release-name');

    // State from data attributes
    var entryId = form.dataset.entryId || '';
    var entryStatus = form.dataset.entryStatus || 'draft';
    var baseUrl = form.dataset.baseUrl || '/admin/content/post';
    var publishedState = form.dataset.publishedState || '';

    // Parse published state for field-level change detection
    var publishedFields = null;
    if (publishedState) {
        try { publishedFields = JSON.parse(publishedState); } catch(e) {}
    }
    var publishFieldsInput = document.getElementById('publish-fields');
    var releaseTriggerText = document.getElementById('release-trigger-text');

    // Parse fields-in-releases: build map of fieldName → {id, name}
    var fieldsInReleases = {};
    var fieldsInReleasesRaw = form.dataset.fieldsInReleases || '[]';
    try {
        var releaseItems = JSON.parse(fieldsInReleasesRaw);
        for (var ri = 0; ri < releaseItems.length; ri++) {
            var item = releaseItems[ri];
            if (item.fields === null) {
                // Full publish — all fields are in this release
                form.querySelectorAll('.form-group[data-field]').forEach(function(g) {
                    if (!fieldsInReleases[g.dataset.field]) {
                        fieldsInReleases[g.dataset.field] = { id: item.id, name: item.name };
                    }
                });
            } else {
                for (var fi = 0; fi < item.fields.length; fi++) {
                    if (!fieldsInReleases[item.fields[fi]]) {
                        fieldsInReleases[item.fields[fi]] = { id: item.id, name: item.name };
                    }
                }
            }
        }
    } catch(e) {}

    // Parse field editors: fields changed by other users
    var fieldEditors = {};
    try {
        fieldEditors = JSON.parse(form.dataset.fieldEditors || '{}');
    } catch(e) {}

    // Populate editor badges and disable fields edited by other users
    form.querySelectorAll('.field-editor-badge[data-field]').forEach(function(badge) {
        var editor = fieldEditors[badge.dataset.field];
        if (editor) {
            badge.innerHTML = '<img src="' + editor.avatar + '" alt="" class="field-editor-avatar" /><span>Edited by ' + editor.name + '</span>';
            badge.classList.add('field-editor-active');
            // Disable the field and mark as hard-locked — backend preserves existing value for absent fields
            var group = badge.closest('.form-group');
            if (group) {
                group.classList.add('field-hard-locked');
                var field = group.querySelector('.form-control');
                if (field) field.disabled = true;
            }
        }
    });

    // Create "In release XXX" links for fields already in a release
    form.querySelectorAll('.form-group[data-field]').forEach(function(group) {
        var rel = fieldsInReleases[group.dataset.field];
        if (rel) {
            var link = document.createElement('a');
            link.href = '/admin/releases/' + rel.id;
            link.className = 'field-release-link';
            link.textContent = 'In release ' + rel.name;
            var checkRow = group.querySelector('.field-check-row');
            if (checkRow) checkRow.appendChild(link);
            else group.querySelector('.form-label-row').appendChild(link);
        }
    });

    // Peek icons (inline SVG for showing published value)
    var peekIconShow = '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M2.42 12.71C2.28 12.5 2.22 12.39 2.18 12.22A.68.68 0 0 1 2.18 11.78C2.22 11.61 2.28 11.5 2.42 11.29 3.55 9.5 6.9 5 12 5s8.45 4.5 9.58 6.29c.14.21.21.32.24.49a.68.68 0 0 1 0 .44c-.04.17-.1.28-.24.49C20.45 14.5 17.1 19 12 19S3.55 14.5 2.42 12.71Z"/><circle cx="12" cy="12" r="3"/></svg>';
    var peekIconHide = '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M10.74 5.09C11.15 5.03 11.57 5 12 5c5.1 0 8.45 4.5 9.58 6.29.14.21.21.32.24.49a.68.68 0 0 1 0 .45c-.04.16-.1.28-.24.49-.3.47-.76 1.14-1.36 1.86M6.72 6.72A14.02 14.02 0 0 0 2.42 11.29c-.14.22-.21.33-.24.49a.68.68 0 0 0 0 .44c.04.17.1.28.24.49C3.55 14.5 6.9 19 12 19c2.06 0 3.83-.73 5.29-1.72M3 3l18 18M9.88 9.88A3 3 0 0 0 9 12a3 3 0 0 0 3 3 3 3 0 0 0 2.12-.88"/></svg>';

    function ensurePeekWrapper(group) {
        var existing = group.querySelector('.field-peek-wrapper');
        if (existing) {
            existing.classList.remove('field-peek-hidden');
            return existing;
        }
        var control = group.querySelector('.form-control');
        if (!control) return null;
        var hadFocus = document.activeElement === control;
        var selStart, selEnd;
        if (hadFocus) {
            try { selStart = control.selectionStart; selEnd = control.selectionEnd; } catch(e) {}
            form.dataset.peekMutating = '1';
        }
        var wrapper = document.createElement('div');
        wrapper.className = 'field-peek-wrapper';
        control.parentNode.insertBefore(wrapper, control);
        wrapper.appendChild(control);
        if (hadFocus) {
            control.focus();
            try { control.setSelectionRange(selStart, selEnd); } catch(e) {}
            delete form.dataset.peekMutating;
        }
        var btn = document.createElement('button');
        btn.type = 'button';
        btn.className = 'field-peek-btn';
        btn.title = 'Show published value';
        btn.innerHTML = peekIconShow;
        wrapper.appendChild(btn);
        var valueBox = document.createElement('div');
        valueBox.className = 'field-peek-value';
        valueBox.style.display = 'none';
        wrapper.after(valueBox);
        btn.addEventListener('click', function() {
            var vb = group.querySelector('.field-peek-value');
            if (vb.style.display === 'none') {
                vb.style.display = '';
                btn.innerHTML = peekIconHide;
                btn.title = 'Hide published value';
            } else {
                vb.style.display = 'none';
                btn.innerHTML = peekIconShow;
                btn.title = 'Show published value';
            }
        });
        return wrapper;
    }

    function removePeekWrapper(group) {
        var wrapper = group.querySelector('.field-peek-wrapper');
        if (!wrapper) return;
        // Hide peek UI without moving the control — avoids focus loss
        wrapper.classList.add('field-peek-hidden');
        var vb = group.querySelector('.field-peek-value');
        if (vb) vb.style.display = 'none';
    }

    function updatePeek(group, publishedValue) {
        var wrapper = ensurePeekWrapper(group);
        if (!wrapper) return;
        var vb = group.querySelector('.field-peek-value');
        if (!vb) return;
        var fieldKey = group.dataset.field;
        var currentValue = getFieldValue(fieldKey);
        var oldDisplay = publishedValue === '' ? '(empty)' : escapeHtml(publishedValue);
        var newDisplay = currentValue === '' ? '(empty)' : escapeHtml(currentValue);
        vb.innerHTML = '<div class="field-peek-row"><span class="field-peek-old">' + oldDisplay + '</span><span class="field-peek-arrow">\u2192</span><span class="field-peek-new">' + newDisplay + '</span></div>';
    }

    function escapeHtml(str) {
        var div = document.createElement('div');
        div.textContent = str;
        return div.innerHTML;
    }

    // Capture form state (excluding meta fields)
    function getFormState() {
        var state = {};
        new FormData(form).forEach(function(value, key) {
            if (key === '_csrf' || key === 'action' || key === 'release_id' || key === 'release_name' || key === 'status' || key === 'fields') return;
            state[key] = value;
        });
        return state;
    }

    var lastSavedState = JSON.stringify(getFormState());
    var saveTimer = null;
    var isSaving = false;
    var isDirty = false;

    function showStatus(type) {
        if (!statusEl) return;
        statusEl.className = 'autosave-status';
        if (type === 'saving') {
            statusEl.textContent = 'Saving...';
            statusEl.classList.add('autosave-status-saving');
        } else if (type === 'saved') {
            statusEl.textContent = 'All changes saved';
            statusEl.classList.add('autosave-status-saved');
        } else if (type === 'error') {
            statusEl.textContent = 'Save failed';
            statusEl.classList.add('autosave-status-error');
        } else if (type === 'rejected') {
            statusEl.classList.add('autosave-status-rejected');
        } else {
            statusEl.textContent = '';
        }
    }

    function onFormChange(e) {
        // Ignore checkbox toggles for field-publish — they don't affect form content
        if (e && e.target && e.target.classList.contains('field-publish-check')) return;
        clearTimeout(saveTimer);
        isDirty = JSON.stringify(getFormState()) !== lastSavedState;
        updateButtons();
        if (isDirty) saveTimer = setTimeout(autoSave, 1500);
    }

    function autoSave() {
        var currentState = getFormState();
        var stateJson = JSON.stringify(currentState);
        if (stateJson === lastSavedState) return;
        if (isSaving) {
            // Retry after current save completes
            saveTimer = setTimeout(autoSave, 500);
            return;
        }

        isSaving = true;
        showStatus('saving');

        fetch(baseUrl + '/' + entryId + '/autosave', {
            method: 'POST',
            headers: {'Content-Type': 'application/x-www-form-urlencoded'},
            body: new URLSearchParams(new FormData(form))
        })
        .then(function(r) { return r.json(); })
        .then(function(data) {
            isSaving = false;
            lastSavedState = stateJson;
            isDirty = false;

            if (data.status) {
                entryStatus = data.status;
                form.dataset.entryStatus = entryStatus;
            }

            // Handle rejected fields (hard lock enforcement)
            if (data.rejected_fields && data.rejected_fields.length > 0) {
                var names = data.rejected_fields.map(function(r) {
                    return r.field + ' (locked by ' + r.owner + ')';
                });
                showStatus('rejected');
                if (statusEl) statusEl.textContent = 'Rejected: ' + names.join(', ');
            } else {
                showStatus('saved');
            }

            updateButtons();
        })
        .catch(function() {
            isSaving = false;
            showStatus('error');
        });
    }

    // Field-level change detection: compare form values against published data
    var changedFieldCount = 0;
    var selectedFieldCount = 0;

    function getFieldValue(fieldKey) {
        // Find .form-control inside the field's group (works regardless of input name)
        var group = form.querySelector('.form-group[data-field="' + fieldKey + '"]');
        if (group) {
            var el = group.querySelector('.form-control');
            if (el) return el.value || '';
            // Boolean fields use form-check-input (checkbox) — use checked state
            var cb = group.querySelector('.form-check-input');
            if (cb) return cb.checked ? 'true' : 'false';
        }
        // Fallback: sidebar fields with form= attribute, or posts name="content" for body
        var formName = fieldKey === 'body' ? 'content' : fieldKey;
        var el = document.querySelector('[name="' + fieldKey + '"][form="entry-form"]') ||
                 document.querySelector('[name="' + formName + '"][form="entry-form"]');
        return el ? (el.value || '') : '';
    }

    function detectChangedFields() {
        if (!publishedFields || entryStatus === 'draft') {
            changedFieldCount = 0;
            selectedFieldCount = 0;
            form.querySelectorAll('.field-peek-wrapper').forEach(function(w) {
                removePeekWrapper(w.closest('.form-group'));
            });
            return;
        }

        var groups = form.querySelectorAll('.form-group[data-field]');
        changedFieldCount = 0;
        selectedFieldCount = 0;

        groups.forEach(function(group) {
            var fieldKey = group.dataset.field;
            var currentValue = getFieldValue(fieldKey);
            var publishedValue = (publishedFields[fieldKey] != null) ? String(publishedFields[fieldKey]) : '';
            var checkbox = group.querySelector('.field-publish-check');

            // Field already in a pending release — show as locked
            if (fieldsInReleases[fieldKey] && currentValue !== publishedValue) {
                group.classList.add('field-in-release');
                group.classList.remove('field-changed', 'field-deselected');
                removePeekWrapper(group);
                return;
            }
            group.classList.remove('field-in-release');

            if (currentValue !== publishedValue) {
                changedFieldCount++;
                updatePeek(group, publishedValue);
                if (checkbox.checked) {
                    group.classList.add('field-changed');
                    group.classList.remove('field-deselected');
                    selectedFieldCount++;
                } else {
                    group.classList.remove('field-changed');
                    group.classList.add('field-deselected');
                }
            } else {
                // Field unchanged — hide checkbox, reset state
                checkbox.checked = true;
                group.classList.remove('field-changed', 'field-deselected');
                removePeekWrapper(group);
            }
        });
    }

    function updateButtons() {
        detectChangedFields();

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

        if (discardBtn) {
            if (entryStatus === 'changed' || (entryStatus === 'published' && isDirty)) {
                discardBtn.classList.remove('hidden');
            } else {
                discardBtn.classList.add('hidden');
            }
        }

        if (releaseTrigger) {
            releaseTrigger.disabled = !entryId || (entryStatus === 'published' && !isDirty);
        }

        // Update release trigger text
        if (releaseTriggerText) {
            if (changedFieldCount > 0 && selectedFieldCount < changedFieldCount && selectedFieldCount > 0) {
                releaseTriggerText.textContent = 'Add ' + selectedFieldCount + '/' + changedFieldCount + ' to Release';
            } else {
                releaseTriggerText.textContent = 'Add to Release';
            }
        }
    }

    // Checkbox change handler
    form.addEventListener('change', function(e) {
        if (e.target.classList.contains('field-publish-check')) {
            updateButtons();
        }
    });

    updateButtons();

    // Sync title input with nav title
    var titleInput = document.getElementById('title');
    var navTitle = document.querySelector('.edit-nav-title');
    if (titleInput && navTitle) {
        titleInput.addEventListener('input', function() {
            navTitle.textContent = titleInput.value || 'Untitled';
        });
    }

    // Listen for changes
    form.addEventListener('input', onFormChange);
    form.addEventListener('change', onFormChange);

    document.querySelectorAll('[form="entry-form"]').forEach(function(el) {
        el.addEventListener('input', onFormChange);
        el.addEventListener('change', onFormChange);
    });

    // Presence events: update UI state without triggering autosave
    form.addEventListener('publr:fields-updated', function() {
        updateButtons();
    });
    form.addEventListener('publr:release-updated', function(e) {
        if (!e.detail || !e.detail.fieldsInReleases) return;
        // Re-parse fieldsInReleases from broadcast data
        fieldsInReleases = {};
        var items = e.detail.fieldsInReleases;
        for (var ri = 0; ri < items.length; ri++) {
            var item = items[ri];
            if (item.fields === null) {
                form.querySelectorAll('.form-group[data-field]').forEach(function(g) {
                    if (!fieldsInReleases[g.dataset.field]) {
                        fieldsInReleases[g.dataset.field] = { id: item.id, name: item.name };
                    }
                });
            } else {
                for (var fi = 0; fi < item.fields.length; fi++) {
                    if (!fieldsInReleases[item.fields[fi]]) {
                        fieldsInReleases[item.fields[fi]] = { id: item.id, name: item.name };
                    }
                }
            }
        }
        // Update release link badges in the form
        form.querySelectorAll('.field-release-link').forEach(function(link) { link.remove(); });
        form.querySelectorAll('.form-group[data-field]').forEach(function(group) {
            var rel = fieldsInReleases[group.dataset.field];
            if (rel) {
                var link = document.createElement('a');
                link.href = '/admin/releases/' + rel.id;
                link.className = 'field-release-link';
                link.textContent = 'In release ' + rel.name;
                var checkRow = group.querySelector('.field-check-row');
                if (checkRow) checkRow.appendChild(link);
                else {
                    var labelRow = group.querySelector('.form-label-row');
                    if (labelRow) labelRow.appendChild(link);
                }
            }
        });
        updateButtons();
    });

    // Discard changes button
    if (discardBtn && entryId) {
        discardBtn.addEventListener('click', function() {
            if (!confirm('Discard all changes and revert to the published version?')) return;
            var csrfField = form.querySelector('input[name="_csrf"]');
            var discardForm = document.createElement('form');
            discardForm.method = 'POST';
            discardForm.action = baseUrl + '/' + entryId + '/discard';
            var csrf = document.createElement('input');
            csrf.type = 'hidden';
            csrf.name = '_csrf';
            csrf.value = csrfField ? csrfField.value : '';
            discardForm.appendChild(csrf);
            document.body.appendChild(discardForm);
            discardForm.submit();
        });
    }

    // Populate fields hidden input with selected field names
    function populateFields() {
        if (!publishFieldsInput) return;
        if (changedFieldCount > 0 && selectedFieldCount < changedFieldCount) {
            var selected = [];
            form.querySelectorAll('.field-publish-check:checked').forEach(function(cb) {
                var group = cb.closest('.form-group[data-field]');
                if (group && group.classList.contains('field-changed')) {
                    selected.push(group.dataset.field);
                }
            });
            publishFieldsInput.value = selected.length > 0 ? JSON.stringify(selected) : '';
        } else {
            publishFieldsInput.value = '';
        }
    }

    // Release dropdown: bind directly to items (content is portalled to body)
    if (releaseDropdown) {
        var releaseContent = releaseDropdown.querySelector('[data-publr-part="content"]');
        if (releaseContent) {
            releaseContent.addEventListener('click', function(e) {
                var item = e.target.closest('[data-release-id]');
                if (item && releaseAction && releaseIdField) {
                    e.preventDefault();
                    e.stopPropagation();
                    releaseAction.value = 'add_to_release';
                    releaseIdField.value = item.dataset.releaseId;
                    releaseNameField.value = '';
                    populateFields();
                    form.submit();
                }
            });
        }

        // Create release button
        var createBtn = document.getElementById('release-create-btn');
        var nameInput = document.getElementById('release-name-input');
        if (createBtn && nameInput) {
            createBtn.addEventListener('click', function(e) {
                e.preventDefault();
                e.stopPropagation();
                var name = nameInput.value.trim();
                if (!name) return;
                releaseAction.value = 'create_release';
                releaseIdField.value = '';
                releaseNameField.value = name;
                populateFields();
                form.submit();
            });
            nameInput.addEventListener('keydown', function(e) {
                if (e.key === 'Enter') {
                    e.preventDefault();
                    createBtn.click();
                }
            });
        }
    }

    // Populate fields hidden input on form submit (publish button)
    form.addEventListener('submit', function() {
        populateFields();
    });
})();

// ── Recompile Nanobar ────────────────────────────
(function() {
    'use strict';

    var STORAGE_KEY = 'publr_recompile';
    var bar = document.getElementById('recompile-bar');
    var barText = document.getElementById('recompile-bar-text');
    var barAction = document.getElementById('recompile-bar-action');
    if (!bar || !barText || !barAction) return;

    function showBar(text, state) {
        barText.textContent = text;
        bar.style.display = '';
        bar.className = 'recompile-bar' + (state ? ' recompile-bar-' + state : '');
        document.body.classList.add('has-recompile-bar');
        barAction.style.display = 'none';
        barAction.onclick = null;
    }

    function showAction(label, onClick) {
        barAction.textContent = label;
        barAction.style.display = '';
        barAction.onclick = function(e) {
            e.preventDefault();
            onClick();
        };
    }

    function hideBar() {
        bar.style.display = 'none';
        document.body.classList.remove('has-recompile-bar');
    }

    function clearState() {
        sessionStorage.removeItem(STORAGE_KEY);
    }

    function getState() {
        try {
            return JSON.parse(sessionStorage.getItem(STORAGE_KEY));
        } catch(e) {
            return null;
        }
    }

    function setState(obj) {
        sessionStorage.setItem(STORAGE_KEY, JSON.stringify(obj));
    }

    function poll(expected, startTime) {
        fetch('/admin/system/health', { cache: 'no-store' })
            .then(function(r) {
                if (!r.ok) throw new Error();
                return r.json();
            })
            .then(function(d) {
                if (d.configText === expected) {
                    setState({ state: 'done' });
                    showBar('Site rebuilt successfully.', 'success');
                    showAction('Refresh page', function() {
                        clearState();
                        location.reload();
                    });
                } else {
                    schedulePoll(expected, startTime);
                }
            })
            .catch(function() {
                schedulePoll(expected, startTime);
            });
    }

    function schedulePoll(expected, startTime) {
        setTimeout(function() {
            var elapsed = Math.round((Date.now() - startTime) / 1000);
            if (elapsed >= 5) {
                showBar('Rebuilding site\u2026 (' + elapsed + 's)', null);
            }
            poll(expected, startTime);
        }, 500);
    }

    // Resume state on every page load
    var saved = getState();
    if (saved) {
        if (saved.state === 'building') {
            showBar('Rebuilding site\u2026', null);
            poll(saved.configText, saved.startTime);
        } else if (saved.state === 'done') {
            showBar('Site rebuilt successfully.', 'success');
            showAction('Refresh page', function() {
                clearState();
                location.reload();
            });
        } else if (saved.state === 'error') {
            showBar(saved.message || 'Build failed.', 'error');
            showAction('Dismiss', function() {
                clearState();
                hideBar();
            });
        }
    }

    // Bind recompile button (only exists on system page)
    var btn = document.getElementById('recompile-btn');
    var input = document.getElementById('config-text');
    var csrfEl = document.querySelector('input[name="_csrf"]');
    if (!btn || !input || !csrfEl) return;

    btn.addEventListener('click', function() {
        var configText = input.value;
        var csrf = csrfEl.value;
        var startTime = Date.now();

        btn.disabled = true;
        btn.textContent = 'Compiling\u2026';
        setState({ state: 'building', configText: configText, startTime: startTime });
        showBar('Rebuilding site\u2026', null);

        fetch('/admin/system/config', {
            method: 'POST',
            headers: {
                'X-CSRF-Token': csrf,
                'Content-Type': 'application/x-www-form-urlencoded'
            },
            body: 'key=configText&value=' + encodeURIComponent(configText)
        })
        .then(function(r) {
            return r.text().then(function(text) {
                var data;
                try { data = JSON.parse(text); } catch(e) {
                    setState({ state: 'error', message: text || 'Unknown error' });
                    showBar(text || 'Unknown error', 'error');
                    showAction('Dismiss', function() { clearState(); hideBar(); });
                    btn.disabled = false;
                    btn.textContent = 'Save & Recompile';
                    return;
                }
                if (!data.success) {
                    setState({ state: 'error', message: data.error });
                    showBar(data.error || 'Build failed.', 'error');
                    showAction('Dismiss', function() { clearState(); hideBar(); });
                    btn.disabled = false;
                    btn.textContent = 'Save & Recompile';
                    return;
                }
                btn.textContent = 'Restarting\u2026';
                poll(configText, startTime);
            });
        })
        .catch(function() {
            // Connection lost — server is restarting, start polling
            btn.textContent = 'Restarting\u2026';
            poll(configText, startTime);
        });
    });
})();

