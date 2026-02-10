// Media library selection & bulk actions
(function () {
  'use strict';

  var selectAllCheckbox = document.getElementById('media-select-all');
  if (!selectAllCheckbox) return; // Not on media page

  var STORAGE_KEY = 'publr-media-selection';
  var selectedIds = new Set();
  var selectAllPages = false;

  // Current filter context (URL without page param)
  function getFilterContext() {
    var params = new URLSearchParams(window.location.search);
    params.delete('page');
    return window.location.pathname + '?' + params.toString();
  }

  // Persist selection to sessionStorage
  function saveSelection() {
    sessionStorage.setItem(STORAGE_KEY, JSON.stringify({
      ids: Array.from(selectedIds),
      selectAllPages: selectAllPages,
      context: getFilterContext(),
    }));
  }

  // Restore selection from sessionStorage
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

  // DOM refs
  var countDefault = document.getElementById('media-count-default');
  var selectionInfo = document.getElementById('media-selection-info');
  var selectionCount = document.getElementById('media-selection-count');
  var banner = document.getElementById('media-select-all-banner');
  var bannerText = document.getElementById('media-select-all-banner-text');
  var selectAllPagesBtn = document.getElementById('media-select-all-pages-btn');
  var selectAllPagesText = document.getElementById('media-select-all-pages-text');
  var clearSelectionBtn = document.getElementById('media-clear-selection-btn');
  var bulkActionsBtn = document.getElementById('media-bulk-actions-btn');

  var filteredCount = banner ? parseInt(banner.dataset.filteredCount, 10) || 0 : 0;
  var itemsPerPage = banner ? parseInt(banner.dataset.itemsPerPage, 10) || 25 : 25;

  function getAllCheckboxes() {
    return document.querySelectorAll('.media-checkbox, .table-checkbox[value]');
  }

  function getVisibleCount() {
    return getAllCheckboxes().length;
  }

  function updateUI() {
    var count = selectAllPages ? filteredCount : selectedIds.size;

    if (count > 0) {
      countDefault.style.display = 'none';
      selectionInfo.style.display = '';
      selectionCount.textContent = count;
      bulkActionsBtn.disabled = false;
    } else {
      countDefault.style.display = '';
      selectionInfo.style.display = 'none';
      bulkActionsBtn.disabled = true;
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
        bannerText.style.display = 'none';
        selectAllPagesBtn.style.display = 'none';
        selectAllPagesText.style.display = '';
        clearSelectionBtn.style.display = '';
      } else {
        bannerText.style.display = '';
        selectAllPagesBtn.style.display = '';
        selectAllPagesText.style.display = 'none';
        clearSelectionBtn.style.display = 'none';
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

  // Individual checkbox change
  document.addEventListener('change', function (e) {
    var cb = e.target;
    if (cb.classList.contains('media-checkbox') || (cb.classList.contains('table-checkbox') && cb.value)) {
      if (cb.checked) {
        selectedIds.add(cb.value);
      } else {
        selectedIds.delete(cb.value);
        selectAllPages = false;
      }
      saveSelection();
      updateUI();
    }
  });

  // Prevent checkbox clicks from navigating in grid view
  document.addEventListener('click', function (e) {
    if (e.target.classList.contains('media-checkbox')) {
      e.stopPropagation();
    }
  }, true);

  // Select-all checkbox
  selectAllCheckbox.addEventListener('change', function () {
    var checkboxes = getAllCheckboxes();
    if (selectAllCheckbox.checked) {
      checkboxes.forEach(function (cb) {
        cb.checked = true;
        selectedIds.add(cb.value);
      });
    } else {
      selectedIds.clear();
      selectAllPages = false;
      checkboxes.forEach(function (cb) { cb.checked = false; });
    }
    saveSelection();
    updateUI();
  });

  // Select all pages button
  if (selectAllPagesBtn) {
    selectAllPagesBtn.addEventListener('click', function () {
      selectAllPages = true;
      saveSelection();
      updateUI();
    });
  }

  // Clear selection button
  if (clearSelectionBtn) {
    clearSelectionBtn.addEventListener('click', function () {
      selectAllPages = false;
      selectedIds.clear();
      getAllCheckboxes().forEach(function (cb) { cb.checked = false; });
      selectAllCheckbox.checked = false;
      saveSelection();
      updateUI();
    });
  }

  // Fill bulk action form fields
  function fillBulkForm(prefix) {
    var idsField = document.getElementById(prefix + '-ids');
    var selectAllField = document.getElementById(prefix + '-select-all');

    if (selectAllPages) {
      if (idsField) idsField.value = '';
      if (selectAllField) selectAllField.value = '1';
      // Fill filter fields from banner data attrs
      var fields = ['folder', 'search', 'unreviewed', 'year', 'month'];
      fields.forEach(function (f) {
        var el = document.getElementById(prefix + '-filter-' + f);
        if (el && banner) {
          var key = 'filter' + f.charAt(0).toUpperCase() + f.slice(1);
          // Map data attribute names
          if (f === 'folder') el.value = banner.dataset.activeFolder || '';
          else if (f === 'search') el.value = banner.dataset.searchTerm || '';
          else if (f === 'unreviewed') el.value = banner.dataset.showUnreviewed || '0';
          else if (f === 'year') el.value = banner.dataset.filterYear || '';
          else if (f === 'month') el.value = banner.dataset.filterMonth || '';
        }
      });
      // Tags from URL
      var tagsField = document.getElementById(prefix + '-filter-tags');
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

  // Bulk action button handlers (event delegation)
  document.addEventListener('click', function (e) {
    var btn = e.target.closest('[data-bulk-action]');
    if (!btn) return;

    var action = btn.dataset.bulkAction;
    var count = selectAllPages ? filteredCount : selectedIds.size;
    if (count === 0) return;

    if (action === 'delete') {
      if (!confirm('Delete ' + count + ' selected items permanently?')) return;
      fillBulkForm('bulk-delete');
      sessionStorage.removeItem(STORAGE_KEY);
      document.getElementById('bulk-delete-form').submit();
    } else if (action === 'add-tag') {
      fillBulkForm('bulk-add-tag');
      var dialog = document.getElementById('bulk-add-tag-dialog');
      if (dialog) dialog.querySelector('[data-publr-part="trigger"]').click();
    } else if (action === 'remove-tag') {
      fillBulkForm('bulk-remove-tag');
      var dialog2 = document.getElementById('bulk-remove-tag-dialog');
      if (dialog2) dialog2.querySelector('[data-publr-part="trigger"]').click();
    } else if (action === 'move-folder') {
      fillBulkForm('bulk-move-folder');
      var dialog3 = document.getElementById('bulk-move-folder-dialog');
      if (dialog3) dialog3.querySelector('[data-publr-part="trigger"]').click();
    }
  });

  // Clear selection after any bulk form submit
  ['bulk-add-tag-form', 'bulk-remove-tag-form', 'bulk-move-folder-form'].forEach(function (id) {
    var form = document.getElementById(id);
    if (form) form.addEventListener('submit', function () { sessionStorage.removeItem(STORAGE_KEY); });
  });

  // Restore selection on page load
  restoreSelection();
  updateUI();
})();
