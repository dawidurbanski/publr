// Media library selection & bulk actions.
//
// Run through the interact runtime: all events are delegated (bound once at
// module load, so they work for media rows/toolbar controls swapped in by
// HMR with no re-binding or leaks), and a `scan` re-syncs the UI after each
// init. Selection state lives at module scope, so it persists across swaps;
// DOM refs are queried fresh on each use (never cached) so they always point
// at the live nodes.

import { delegate, scan } from './interact/core.js';

'use strict';

var STORAGE_KEY = 'publr-media-selection';
var selectedIds = new Set();
var selectAllPages = false;

// ── DOM refs (queried fresh — the media list can be swapped in by HMR) ───
function $(id) { return document.getElementById(id); }
function getAllCheckboxes() {
    return document.querySelectorAll('.media-checkbox, .table-checkbox[value]');
}
function getVisibleCount() {
    return getAllCheckboxes().length;
}

// Current filter context (URL without page param)
function getFilterContext() {
    var params = new URLSearchParams(window.location.search);
    params.delete('page');
    return window.location.pathname + '?' + params.toString();
}

function saveSelection() {
    sessionStorage.setItem(STORAGE_KEY, JSON.stringify({
        ids: Array.from(selectedIds),
        selectAllPages: selectAllPages,
        context: getFilterContext(),
    }));
}

function restoreSelection() {
    var raw = sessionStorage.getItem(STORAGE_KEY);
    if (!raw) return;
    try {
        var data = JSON.parse(raw);
        // Clear selection if filters/folder changed
        if (data.context && data.context !== getFilterContext()) {
            sessionStorage.removeItem(STORAGE_KEY);
            return;
        }
        if (data.ids) data.ids.forEach(function (id) { selectedIds.add(id); });
        if (data.selectAllPages) selectAllPages = true;
        // Sync checkboxes with restored state
        getAllCheckboxes().forEach(function (cb) {
            if (selectAllPages) {
                cb.checked = true;
                selectedIds.add(cb.value);
            } else {
                cb.checked = selectedIds.has(cb.value);
            }
        });
        if (selectAllPages) saveSelection();
    } catch (e) { /* ignore corrupt data */ }
}

function updateUI() {
    var selectAllCheckbox = $('media-select-all');
    if (!selectAllCheckbox) return; // not on the media page
    var countDefault = $('media-count-default');
    var selectionInfo = $('media-selection-info');
    var selectionCount = $('media-selection-count');
    var banner = $('media-select-all-banner');
    var bannerText = $('media-select-all-banner-text');
    var selectAllPagesBtn = $('media-select-all-pages-btn');
    var selectAllPagesText = $('media-select-all-pages-text');
    var clearSelectionBtn = $('media-clear-selection-btn');
    var bulkActionsBtn = $('media-bulk-actions-btn');
    var filteredCount = banner ? parseInt(banner.dataset.filteredCount, 10) || 0 : 0;
    var itemsPerPage = banner ? parseInt(banner.dataset.itemsPerPage, 10) || 25 : 25;

    var count = selectAllPages ? filteredCount : selectedIds.size;

    if (count > 0) {
        if (countDefault) countDefault.style.display = 'none';
        if (selectionInfo) selectionInfo.style.display = '';
        if (selectionCount) selectionCount.textContent = count;
        if (bulkActionsBtn) bulkActionsBtn.disabled = false;
    } else {
        if (countDefault) countDefault.style.display = '';
        if (selectionInfo) selectionInfo.style.display = 'none';
        if (bulkActionsBtn) bulkActionsBtn.disabled = true;
    }

    // Select-all checkbox state
    var visibleCount = getVisibleCount();
    var allVisibleSelected = visibleCount > 0 && selectedIds.size >= visibleCount;
    selectAllCheckbox.checked = allVisibleSelected;
    selectAllCheckbox.indeterminate = selectedIds.size > 0 && !allVisibleSelected;

    // Select-all banner
    if (banner) {
        var showBanner = allVisibleSelected && filteredCount > itemsPerPage;
        banner.style.display = showBanner ? '' : 'none';

        if (selectAllPages) {
            if (bannerText) bannerText.style.display = 'none';
            if (selectAllPagesBtn) selectAllPagesBtn.style.display = 'none';
            if (selectAllPagesText) selectAllPagesText.style.display = '';
            if (clearSelectionBtn) clearSelectionBtn.style.display = '';
        } else {
            if (bannerText) bannerText.style.display = '';
            if (selectAllPagesBtn) selectAllPagesBtn.style.display = '';
            if (selectAllPagesText) selectAllPagesText.style.display = 'none';
            if (clearSelectionBtn) clearSelectionBtn.style.display = 'none';
        }
    }

    // Card/row selection states
    document.querySelectorAll('.media-card').forEach(function (card) {
        var id = card.dataset.mediaId;
        card.classList.toggle('selected', selectedIds.has(id));
    });
    document.querySelectorAll('.table-checkbox[value]').forEach(function (cb) {
        var row = cb.closest('tr');
        if (row) row.classList.toggle('selected', selectedIds.has(cb.value));
    });
}

// Fill bulk action form fields
function fillBulkForm(prefix) {
    var banner = $('media-select-all-banner');
    var idsField = $(prefix + '-ids');
    var selectAllField = $(prefix + '-select-all');

    if (selectAllPages) {
        if (idsField) idsField.value = '';
        if (selectAllField) selectAllField.value = '1';
        // Fill filter fields from banner data attrs
        var fields = ['folder', 'search', 'unreviewed', 'year', 'month'];
        fields.forEach(function (f) {
            var el = $(prefix + '-filter-' + f);
            if (el && banner) {
                if (f === 'folder') el.value = banner.dataset.activeFolder || '';
                else if (f === 'search') el.value = banner.dataset.searchTerm || '';
                else if (f === 'unreviewed') el.value = banner.dataset.showUnreviewed || '0';
                else if (f === 'year') el.value = banner.dataset.filterYear || '';
                else if (f === 'month') el.value = banner.dataset.filterMonth || '';
            }
        });
        // Tags from URL
        var tagsField = $(prefix + '-filter-tags');
        if (tagsField) {
            var params = new URLSearchParams(window.location.search);
            var tags = params.getAll('tag');
            tagsField.value = tags.join(',');
        }
    } else {
        if (idsField) idsField.value = Array.from(selectedIds).join(',');
        if (selectAllField) selectAllField.value = '';
    }
}

// ── Delegated events (bound once; work for swapped-in nodes) ─────────────

// Individual row checkbox toggled.
delegate('change', '.media-checkbox, .table-checkbox[value]', function (e, cb) {
    if (cb.checked) {
        selectedIds.add(cb.value);
    } else {
        selectedIds.delete(cb.value);
        selectAllPages = false;
    }
    saveSelection();
    updateUI();
});

// Master "select all (visible)" checkbox.
delegate('change', '#media-select-all', function () {
    var selectAllCheckbox = $('media-select-all');
    var checkboxes = getAllCheckboxes();
    if (selectAllCheckbox.checked) {
        checkboxes.forEach(function (cb) { cb.checked = true; selectedIds.add(cb.value); });
    } else {
        selectedIds.clear();
        selectAllPages = false;
        checkboxes.forEach(function (cb) { cb.checked = false; });
    }
    saveSelection();
    updateUI();
});

// "Select all N across pages" button.
delegate('click', '#media-select-all-pages-btn', function () {
    selectAllPages = true;
    saveSelection();
    updateUI();
});

// "Clear selection" button.
delegate('click', '#media-clear-selection-btn', function () {
    selectAllPages = false;
    selectedIds.clear();
    getAllCheckboxes().forEach(function (cb) { cb.checked = false; });
    var selectAllCheckbox = $('media-select-all');
    if (selectAllCheckbox) selectAllCheckbox.checked = false;
    saveSelection();
    updateUI();
});

// Bulk action buttons.
delegate('click', '[data-bulk-action]', function (e, btn) {
    var action = btn.dataset.bulkAction;
    var banner = $('media-select-all-banner');
    var filteredCount = banner ? parseInt(banner.dataset.filteredCount, 10) || 0 : 0;
    var count = selectAllPages ? filteredCount : selectedIds.size;
    if (count === 0) return;

    if (action === 'delete') {
        if (!confirm('Delete ' + count + ' selected items permanently?')) return;
        fillBulkForm('bulk-delete');
        sessionStorage.removeItem(STORAGE_KEY);
        $('bulk-delete-form').submit();
    } else if (action === 'add-tag') {
        fillBulkForm('bulk-add-tag');
        var dialog = $('bulk-add-tag-dialog');
        if (dialog) dialog.querySelector('[data-publr-part="trigger"]').click();
    } else if (action === 'remove-tag') {
        fillBulkForm('bulk-remove-tag');
        var dialog2 = $('bulk-remove-tag-dialog');
        if (dialog2) dialog2.querySelector('[data-publr-part="trigger"]').click();
    } else if (action === 'move-folder') {
        fillBulkForm('bulk-move-folder');
        var dialog3 = $('bulk-move-folder-dialog');
        if (dialog3) dialog3.querySelector('[data-publr-part="trigger"]').click();
    }
});

// Clear persisted selection after any bulk form submit.
delegate('submit', '#bulk-add-tag-form, #bulk-remove-tag-form, #bulk-move-folder-form', function () {
    sessionStorage.removeItem(STORAGE_KEY);
});

// Prevent checkbox clicks from navigating in grid view. Capture phase (so it
// runs before the card's own click handler), bound once at module load.
document.addEventListener('click', function (e) {
    if (e.target.classList && e.target.classList.contains('media-checkbox')) {
        e.stopPropagation();
    }
}, true);

// ── Re-sync on every init (incl. after HMR swaps) ────────────────────────
scan(function () {
    if (!$('media-select-all')) return; // not on the media page
    restoreSelection();
    updateUI();
});
