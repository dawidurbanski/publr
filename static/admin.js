// Publr Admin — Component Handlers
// Admin-specific wiring. Depends on interact modules (core, toggle, portal, focus-trap, dismiss).
// Component handlers are registered here; tasks 03-06 add the implementations.
(function() {
    'use strict';

    // Component handlers will be registered like:
    // publr.register('dialog', function(el) { ... });
    // publr.register('dropdown', function(el) { ... });

    // ── Media Upload Zone ───────────────────────────────
    var zone = document.getElementById('media-upload-zone');
    if (zone) {
        var fileInput = document.getElementById('media-file-input');
        var form = document.getElementById('media-upload-form');
        var progressWrap = document.getElementById('upload-progress');
        var progressBar = document.getElementById('upload-progress-bar');
        var progressText = document.getElementById('upload-progress-text');
        var content = zone.querySelector('.upload-zone-content');

        function uploadFiles(files) {
            if (!files || files.length === 0) return;

            var csrf = form.querySelector('input[name="_csrf"]').value;
            var done = 0;
            var total = files.length;

            content.style.display = 'none';
            progressWrap.style.display = '';
            progressText.textContent = 'Uploading ' + total + ' file' + (total > 1 ? 's' : '') + '...';
            progressBar.style.setProperty('--progress', '0%');

            function uploadNext(i) {
                if (i >= total) {
                    window.location.reload();
                    return;
                }
                var fd = new FormData();
                fd.append('_csrf', csrf);
                fd.append('file', files[i]);

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

        // Drag and drop
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
            uploadFiles(e.dataTransfer.files);
        });

        // Click to upload triggers file input
        if (fileInput) {
            fileInput.addEventListener('change', function() {
                uploadFiles(fileInput.files);
            });
        }

        // Prevent form from submitting normally
        form.addEventListener('submit', function(e) {
            e.preventDefault();
            uploadFiles(fileInput.files);
        });
    }

})();
