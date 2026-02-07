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
