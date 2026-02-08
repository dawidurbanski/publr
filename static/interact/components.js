// Publr Interactivity — Component Handlers
// Registers handlers for: toggle, dialog, dropdown, select, popover, tooltip, toast, tabs, switch.

import { register } from './core.js';
import { open, close, toggle, isOpen } from './toggle.js';
import { portal, unportal, position } from './portal.js';
import { trapFocus, releaseFocus } from './focus-trap.js';

let uid = 0;
function nextId(prefix) {
    return 'publr-' + prefix + '-' + (++uid);
}

// ── Toggle ──────────────────────────────────────
register('toggle', (el) => {
    const trigger = el.querySelector('[data-publr-part="trigger"]');
    if (!trigger) return;
    trigger.addEventListener('click', () => toggle(el));
});

// ── Dialog ──────────────────────────────────────
register('dialog', (el) => {
    const trigger = el.querySelector('[data-publr-part="trigger"]');
    const content = el.querySelector('[data-publr-part="content"]');
    const closeBtn = el.querySelector('[data-publr-part="close"]');
    if (!trigger || !content) return;

    trigger.addEventListener('click', () => {
        open(el);
        trapFocus(content);
        el._publrOnClose = () => {
            releaseFocus(content);
            trigger.focus();
        };
    });

    if (closeBtn) {
        closeBtn.addEventListener('click', () => close(el));
    }

    // Overlay click (only if dismissable)
    content.addEventListener('click', (e) => {
        if (e.target === content && el.dataset.publrDismissable !== 'false') {
            close(el);
        }
    });
});

// ── Dropdown Menu ───────────────────────────────
register('dropdown', (el) => {
    const trigger = el.querySelector('[data-publr-part="trigger"]');
    const content = el.querySelector('[data-publr-part="content"]');
    if (!trigger || !content) return;
    el._publrContent = content;

    trigger.addEventListener('click', () => {
        if (isOpen(el)) {
            close(el);
        } else {
            open(el);
            portal(content);
            position(content, trigger);
            el._publrOnClose = () => unportal(content);
            const first = content.querySelector('[data-publr-part="item"]');
            if (first) first.focus();
        }
    });

    // Keyboard navigation
    content.addEventListener('keydown', (e) => {
        const items = content.querySelectorAll('[data-publr-part="item"]');
        if (!items.length) return;
        const idx = Array.from(items).indexOf(document.activeElement);

        if (e.key === 'ArrowDown') {
            e.preventDefault();
            items[(idx + 1) % items.length].focus();
        } else if (e.key === 'ArrowUp') {
            e.preventDefault();
            items[(idx - 1 + items.length) % items.length].focus();
        } else if (e.key === 'Home') {
            e.preventDefault();
            items[0].focus();
        } else if (e.key === 'End') {
            e.preventDefault();
            items[items.length - 1].focus();
        } else if (e.key === 'Enter') {
            e.preventDefault();
            if (idx >= 0) items[idx].click();
        }
    });

    // Item click closes
    content.querySelectorAll('[data-publr-part="item"]').forEach(item => {
        item.addEventListener('click', () => {
            close(el);
            trigger.focus();
        });
    });
});

// ── Select ──────────────────────────────────────
register('select', (el) => {
    const trigger = el.querySelector('[data-publr-part="trigger"]');
    const content = el.querySelector('[data-publr-part="content"]');
    const hidden = el.querySelector('[data-publr-part="value"]');
    const label = el.querySelector('[data-publr-part="label"]');
    if (!trigger || !content) return;
    el._publrContent = content;

    trigger.addEventListener('click', () => {
        if (isOpen(el)) {
            close(el);
        } else {
            open(el);
            portal(content);
            position(content, trigger);
            el._publrOnClose = () => unportal(content);
            const selected = content.querySelector('[aria-selected="true"]') || content.querySelector('[data-publr-part="item"]');
            if (selected) selected.focus();
        }
    });

    // Keyboard navigation + type-ahead
    let typeBuffer = '';
    let typeTimer = null;
    content.addEventListener('keydown', (e) => {
        const items = content.querySelectorAll('[data-publr-part="item"]');
        if (!items.length) return;
        const idx = Array.from(items).indexOf(document.activeElement);

        if (e.key === 'ArrowDown') {
            e.preventDefault();
            items[(idx + 1) % items.length].focus();
        } else if (e.key === 'ArrowUp') {
            e.preventDefault();
            items[(idx - 1 + items.length) % items.length].focus();
        } else if (e.key === 'Home') {
            e.preventDefault();
            items[0].focus();
        } else if (e.key === 'End') {
            e.preventDefault();
            items[items.length - 1].focus();
        } else if (e.key === 'Enter') {
            e.preventDefault();
            if (idx >= 0) items[idx].click();
        } else if (e.key.length === 1 && !e.ctrlKey && !e.metaKey) {
            typeBuffer += e.key.toLowerCase();
            clearTimeout(typeTimer);
            typeTimer = setTimeout(() => { typeBuffer = ''; }, 500);
            for (const item of items) {
                if (item.textContent.trim().toLowerCase().startsWith(typeBuffer)) {
                    item.focus();
                    break;
                }
            }
        }
    });

    // Item selection
    content.querySelectorAll('[data-publr-part="item"]').forEach(item => {
        item.addEventListener('click', function() {
            const val = this.dataset.value;
            const text = this.textContent;
            if (hidden) hidden.value = val;
            if (label) label.textContent = text;
            content.querySelectorAll('[data-publr-part="item"]').forEach(i => {
                i.setAttribute('aria-selected', i === this ? 'true' : 'false');
            });
            close(el);
            trigger.focus();
        });
    });
});

// ── Popover ─────────────────────────────────────
register('popover', (el) => {
    const trigger = el.querySelector('[data-publr-part="trigger"]');
    const content = el.querySelector('[data-publr-part="content"]');
    if (!trigger || !content) return;
    el._publrContent = content;
    const id = nextId('popover');
    content.id = id;
    trigger.setAttribute('aria-controls', id);

    trigger.addEventListener('click', () => {
        if (isOpen(el)) {
            close(el);
        } else {
            open(el);
            portal(content);
            position(content, trigger);
            el._publrOnClose = () => unportal(content);
        }
    });
});

// ── Tooltip ─────────────────────────────────────
// Tooltips manage state directly — no openStack interaction.
// They respond only to hover/focus, not click-outside or Escape.
register('tooltip', (el) => {
    const trigger = el.querySelector('[data-publr-part="trigger"]');
    const content = el.querySelector('[data-publr-part="content"]');
    if (!trigger || !content) return;
    const id = nextId('tooltip');
    content.id = id;
    trigger.setAttribute('aria-describedby', id);
    let timer = null;

    function show() {
        timer = setTimeout(() => {
            el.dataset.publrState = 'open';
            portal(content);
            position(content, trigger);
        }, 200);
    }

    function hide() {
        clearTimeout(timer);
        if (el.dataset.publrState === 'open') {
            el.dataset.publrState = 'closed';
            unportal(content);
        }
    }

    trigger.addEventListener('mouseenter', show);
    trigger.addEventListener('mouseleave', hide);
    trigger.addEventListener('focus', show);
    trigger.addEventListener('blur', hide);
    trigger.addEventListener('keydown', (e) => {
        if (e.key === 'Escape') hide();
    });
});

// ── Toast ───────────────────────────────────────
let toastRegion = null;

function getToastRegion() {
    if (!toastRegion) {
        toastRegion = document.createElement('div');
        toastRegion.className = 'toast-region';
        toastRegion.setAttribute('aria-live', 'polite');
        document.body.appendChild(toastRegion);
    }
    return toastRegion;
}

function dismissToast(toast) {
    toast.classList.remove('toast-visible');
    toast.classList.add('toast-exit');
    setTimeout(() => {
        if (toast.parentNode) toast.parentNode.removeChild(toast);
    }, 300);
}

export function toast(message, variant) {
    const region = getToastRegion();
    const toastEl = document.createElement('div');
    toastEl.className = 'toast toast-' + (variant || 'info');
    toastEl.setAttribute('role', 'status');

    const text = document.createElement('span');
    text.textContent = message;
    toastEl.appendChild(text);

    const closeBtn = document.createElement('button');
    closeBtn.className = 'toast-close';
    closeBtn.setAttribute('aria-label', 'Dismiss');
    closeBtn.textContent = '\u00d7';
    let autoTimer;
    closeBtn.addEventListener('click', () => {
        clearTimeout(autoTimer);
        dismissToast(toastEl);
    });
    toastEl.appendChild(closeBtn);

    region.appendChild(toastEl);

    requestAnimationFrame(() => {
        toastEl.classList.add('toast-visible');
    });

    autoTimer = setTimeout(() => {
        dismissToast(toastEl);
    }, 4000);
}

// ── Tabs ────────────────────────────────────────
register('tabs', (el) => {
    const triggers = el.querySelectorAll('[data-publr-part="trigger"]');
    const panels = el.querySelectorAll('[data-publr-part="panel"]');

    // Wire up aria-controls / aria-labelledby with generated IDs
    triggers.forEach(trigger => {
        const tabId = trigger.dataset.publrTab;
        const triggerId = nextId('tab');
        const panelId = nextId('tabpanel');
        trigger.id = triggerId;
        trigger.setAttribute('aria-controls', panelId);
        panels.forEach(panel => {
            if (panel.dataset.publrTab === tabId) {
                panel.id = panelId;
                panel.setAttribute('aria-labelledby', triggerId);
            }
        });
    });

    function activate(tab) {
        const id = tab.dataset.publrTab;
        triggers.forEach(t => {
            t.setAttribute('aria-selected', t === tab ? 'true' : 'false');
            t.setAttribute('tabindex', t === tab ? '0' : '-1');
        });
        panels.forEach(p => {
            if (p.dataset.publrTab === id) {
                p.removeAttribute('hidden');
            } else {
                p.setAttribute('hidden', 'true');
            }
        });
    }

    triggers.forEach(trigger => {
        trigger.addEventListener('click', () => activate(trigger));
    });

    el.addEventListener('keydown', (e) => {
        if (e.target.dataset.publrPart !== 'trigger') return;
        const idx = Array.from(triggers).indexOf(e.target);
        if (e.key === 'ArrowRight') {
            e.preventDefault();
            const next = triggers[(idx + 1) % triggers.length];
            next.focus();
            activate(next);
        } else if (e.key === 'ArrowLeft') {
            e.preventDefault();
            const prev = triggers[(idx - 1 + triggers.length) % triggers.length];
            prev.focus();
            activate(prev);
        } else if (e.key === 'Home') {
            e.preventDefault();
            triggers[0].focus();
            activate(triggers[0]);
        } else if (e.key === 'End') {
            e.preventDefault();
            triggers[triggers.length - 1].focus();
            activate(triggers[triggers.length - 1]);
        }
    });
});

// ── Switch ──────────────────────────────────────
register('switch', (el) => {
    const input = el.querySelector('[data-publr-part="input"]');
    const track = el.querySelector('[data-publr-part="track"]');
    if (!input || !track) return;

    function sync() {
        track.setAttribute('aria-checked', input.checked ? 'true' : 'false');
    }

    input.addEventListener('change', sync);
    sync();
});

// ── Checkbox Group ──────────────────────────────
register('checkbox-group', () => {
    // Semantic HTML handles behavior
});

// ── Radio Group ─────────────────────────────────
register('radio-group', (el) => {
    el.addEventListener('keydown', (e) => {
        if (e.key !== 'ArrowDown' && e.key !== 'ArrowUp') return;
        const radios = el.querySelectorAll('input[type="radio"]');
        if (!radios.length) return;
        const idx = Array.from(radios).indexOf(document.activeElement);
        if (idx === -1) return;
        e.preventDefault();
        let next;
        if (e.key === 'ArrowDown') {
            next = radios[(idx + 1) % radios.length];
        } else {
            next = radios[(idx - 1 + radios.length) % radios.length];
        }
        next.checked = true;
        next.focus();
        next.dispatchEvent(new Event('change', { bubbles: true }));
    });
});

// ── Focal Point ────────────────────────────────
register('focal-point', (el) => {
    const img = el.querySelector('[data-publr-part="image"]');
    const marker = el.querySelector('[data-publr-part="marker"]');
    const label = el.querySelector('[data-publr-part="label"]');
    const inputId = el.dataset.publrInput;
    const input = inputId ? document.getElementById(inputId) : null;
    if (!img || !marker) return;

    function set(x, y) {
        x = Math.max(0, Math.min(100, Math.round(x)));
        y = Math.max(0, Math.min(100, Math.round(y)));
        marker.style.left = x + '%';
        marker.style.top = y + '%';
        marker.style.display = 'block';
        if (label) {
            label.textContent = x + ', ' + y;
            label.style.display = 'block';
        }
        if (input) input.value = x + ',' + y;
    }

    // Initialize from data attribute
    const initial = el.dataset.publrValue;
    if (initial && initial.indexOf(',') !== -1) {
        const parts = initial.split(',');
        set(parseFloat(parts[0]), parseFloat(parts[1]));
    } else {
        set(50, 50);
    }

    el.addEventListener('click', (e) => {
        const rect = img.getBoundingClientRect();
        const x = ((e.clientX - rect.left) / rect.width) * 100;
        const y = ((e.clientY - rect.top) / rect.height) * 100;
        set(x, y);
    });
});

// ── Inline Create ──────────────────────────────
register('inline-create', (el) => {
    const targetId = el.dataset.publrTarget;
    if (!targetId) return;
    const form = document.getElementById(targetId);
    if (!form) return;

    function showForm() {
        form.style.display = '';
        const input = form.querySelector('input[type="text"]');
        if (input) input.focus();
    }

    function hideForm() {
        form.style.display = 'none';
    }

    el.addEventListener('click', (e) => {
        e.preventDefault();
        if (form.style.display === 'none') {
            showForm();
        } else {
            hideForm();
        }
    });

    form.addEventListener('keydown', (e) => {
        if (e.key === 'Escape') {
            hideForm();
            el.focus();
        }
    });
});

// ── Tag Picker ─────────────────────────────────
register('tag-picker', (el) => {
    const selectedContainer = el.querySelector('[data-publr-part="selected"]');
    const searchInput = el.querySelector('[data-publr-part="search"]');
    const dropdown = el.querySelector('[data-publr-part="dropdown"]');
    const optionsContainer = el.querySelector('[data-publr-part="options"]');
    const createBtn = el.querySelector('[data-publr-part="create"]');
    const hidden = el.querySelector('[data-publr-part="hidden"]');
    if (!searchInput || !dropdown || !hidden) return;

    function syncHidden() {
        const names = [];
        selectedContainer.querySelectorAll('.tag-picker-chip').forEach(chip => {
            names.push(chip.dataset.tagName);
        });
        hidden.value = names.join(', ');
    }

    function addChip(name, id) {
        // Check if chip already exists
        const existing = selectedContainer.querySelector('[data-tag-name="' + name + '"]');
        if (existing) return;

        const chip = document.createElement('span');
        chip.className = 'tag-picker-chip';
        chip.dataset.tagName = name;
        if (id) chip.dataset.tagId = id;
        else chip.dataset.tagCustom = 'true';
        chip.textContent = name;

        const removeBtn = document.createElement('button');
        removeBtn.type = 'button';
        removeBtn.className = 'tag-picker-chip-remove';
        removeBtn.setAttribute('aria-label', 'Remove tag');
        removeBtn.innerHTML = '&times;';
        removeBtn.addEventListener('click', () => {
            chip.remove();
            // Uncheck matching option
            const cb = optionsContainer.querySelector('input[value="' + name + '"]');
            if (cb) cb.checked = false;
            syncHidden();
        });

        chip.appendChild(removeBtn);
        selectedContainer.appendChild(chip);
    }

    function removeChip(name) {
        const chip = selectedContainer.querySelector('[data-tag-name="' + name + '"]');
        if (chip) chip.remove();
    }

    // Wire existing remove buttons on server-rendered chips
    selectedContainer.querySelectorAll('[data-publr-part="remove"]').forEach(btn => {
        btn.addEventListener('click', () => {
            const chip = btn.closest('.tag-picker-chip');
            const name = chip.dataset.tagName;
            chip.remove();
            const cb = optionsContainer.querySelector('input[value="' + name + '"]');
            if (cb) cb.checked = false;
            syncHidden();
        });
    });

    // Checkbox changes
    optionsContainer.querySelectorAll('[data-publr-part="option"]').forEach(cb => {
        cb.addEventListener('change', () => {
            if (cb.checked) {
                addChip(cb.value, cb.dataset.tagId);
            } else {
                removeChip(cb.value);
            }
            syncHidden();
        });
    });

    // Search input
    searchInput.addEventListener('focus', () => {
        dropdown.style.display = '';
        filterOptions();
    });

    searchInput.addEventListener('input', () => {
        filterOptions();
    });

    function filterOptions() {
        const query = searchInput.value.trim().toLowerCase();
        let hasExactMatch = false;
        const options = optionsContainer.querySelectorAll('.tag-picker-option');
        options.forEach(opt => {
            const name = opt.querySelector('input').value.toLowerCase();
            if (query.length === 0 || name.indexOf(query) !== -1) {
                opt.style.display = '';
            } else {
                opt.style.display = 'none';
            }
            if (name === query) hasExactMatch = true;
        });

        if (query.length > 0 && !hasExactMatch) {
            createBtn.textContent = 'Create tag: ' + searchInput.value.trim();
            createBtn.style.display = '';
        } else {
            createBtn.style.display = 'none';
        }
    }

    // Create button
    if (createBtn) {
        createBtn.addEventListener('click', () => {
            const name = searchInput.value.trim();
            if (name.length === 0) return;
            addChip(name, null);
            searchInput.value = '';
            createBtn.style.display = 'none';
            filterOptions();
            syncHidden();
        });
    }

    // Enter key triggers create
    searchInput.addEventListener('keydown', (e) => {
        if (e.key === 'Enter') {
            e.preventDefault();
            if (createBtn && createBtn.style.display !== 'none') {
                createBtn.click();
            }
        } else if (e.key === 'Escape') {
            dropdown.style.display = 'none';
            searchInput.blur();
        }
    });

    // Click outside closes dropdown
    document.addEventListener('click', (e) => {
        if (!el.contains(e.target)) {
            dropdown.style.display = 'none';
        }
    });
});

// ── Nav Slider ─────────────────────────────────
register('nav-slider', (el) => {
    const slider = el.querySelector('.nav-slider');
    const triggers = el.querySelectorAll('[data-publr-part="trigger"]');
    const backBtns = el.querySelectorAll('[data-publr-part="back"]');
    if (!slider) return;

    triggers.forEach(trigger => {
        trigger.addEventListener('click', () => {
            slider.classList.add('submenu-open');
        });
    });

    backBtns.forEach(btn => {
        btn.addEventListener('click', () => {
            slider.classList.remove('submenu-open');
        });
    });
});

// ── Image Picker ───────────────────────────────
let imagePickerModal = null;
let currentImagePicker = null;
let pickerActiveFolder = '';
let pickerActiveTags = [];

function getImagePickerModal() {
    if (imagePickerModal) return imagePickerModal;

    // Create modal HTML with sidebar layout
    const modal = document.createElement('div');
    modal.className = 'image-picker-modal';
    modal.innerHTML = `
        <div class="image-picker-modal-content">
            <div class="image-picker-modal-header">
                <h3>Select Image</h3>
                <button type="button" class="image-picker-modal-close" aria-label="Close">&times;</button>
            </div>
            <div class="image-picker-modal-layout">
                <aside class="image-picker-modal-sidebar">
                    <div class="image-picker-modal-section">
                        <h4 class="image-picker-modal-section-title">Folders</h4>
                        <ul class="image-picker-modal-folders"></ul>
                    </div>
                    <div class="image-picker-modal-section">
                        <h4 class="image-picker-modal-section-title">Tags</h4>
                        <div class="image-picker-modal-tags"></div>
                    </div>
                </aside>
                <div class="image-picker-modal-main">
                    <div class="image-picker-modal-toolbar">
                        <div class="image-picker-modal-search">
                            <svg class="icon icon-sm" viewBox="0 0 24 24" fill="none"><path d="M21 21L17.5001 17.5M20 11.5C20 16.1944 16.1944 20 11.5 20C6.80558 20 3 16.1944 3 11.5C3 6.80558 6.80558 3 11.5 3C16.1944 3 20 6.80558 20 11.5Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>
                            <input type="text" placeholder="Search media..." />
                        </div>
                    </div>
                    <div class="image-picker-modal-body">
                        <div class="image-picker-modal-grid"></div>
                    </div>
                </div>
            </div>
            <div class="image-picker-modal-footer">
                <div class="image-picker-modal-info"></div>
                <div class="image-picker-modal-actions">
                    <button type="button" class="btn btn-sm" data-action="cancel">Cancel</button>
                    <button type="button" class="btn btn-sm btn-primary" data-action="select" disabled>Select</button>
                </div>
            </div>
        </div>
    `;
    document.body.appendChild(modal);
    imagePickerModal = modal;

    // Wire up modal events
    const closeBtn = modal.querySelector('.image-picker-modal-close');
    const cancelBtn = modal.querySelector('[data-action="cancel"]');
    const selectBtn = modal.querySelector('[data-action="select"]');
    const searchInput = modal.querySelector('.image-picker-modal-search input');
    const grid = modal.querySelector('.image-picker-modal-grid');
    const foldersContainer = modal.querySelector('.image-picker-modal-folders');
    const tagsContainer = modal.querySelector('.image-picker-modal-tags');

    closeBtn.addEventListener('click', closeImagePickerModal);
    cancelBtn.addEventListener('click', closeImagePickerModal);

    modal.addEventListener('click', (e) => {
        if (e.target === modal) closeImagePickerModal();
    });

    document.addEventListener('keydown', (e) => {
        if (e.key === 'Escape' && modal.classList.contains('open')) {
            closeImagePickerModal();
        }
    });

    selectBtn.addEventListener('click', () => {
        const selected = grid.querySelector('.selected');
        if (selected && currentImagePicker) {
            const mediaId = selected.dataset.mediaId;
            const thumbUrl = selected.dataset.thumbUrl;
            const altText = selected.dataset.altText || '';
            selectImage(currentImagePicker, mediaId, thumbUrl, altText);
            closeImagePickerModal();
        }
    });

    let searchTimer = null;
    searchInput.addEventListener('input', () => {
        clearTimeout(searchTimer);
        searchTimer = setTimeout(() => {
            loadMediaItems(searchInput.value);
        }, 300);
    });

    // Folder click handler
    foldersContainer.addEventListener('click', (e) => {
        const item = e.target.closest('.image-picker-modal-folder');
        if (!item) return;
        e.preventDefault();
        pickerActiveFolder = item.dataset.folderId || '';
        loadMediaItems(searchInput.value);
    });

    // Tag click handler
    tagsContainer.addEventListener('click', (e) => {
        const chip = e.target.closest('.image-picker-modal-tag');
        if (!chip) return;
        e.preventDefault();
        const tagId = chip.dataset.tagId;
        if (pickerActiveTags.includes(tagId)) {
            pickerActiveTags = pickerActiveTags.filter(t => t !== tagId);
        } else {
            pickerActiveTags.push(tagId);
        }
        loadMediaItems(searchInput.value);
    });

    // Grid item selection
    grid.addEventListener('click', (e) => {
        const item = e.target.closest('.image-picker-modal-item');
        if (!item) return;

        grid.querySelectorAll('.image-picker-modal-item').forEach(i => {
            i.classList.remove('selected');
        });
        item.classList.add('selected');
        selectBtn.disabled = false;
    });

    // Double-click to select immediately
    grid.addEventListener('dblclick', (e) => {
        const item = e.target.closest('.image-picker-modal-item');
        if (!item || !currentImagePicker) return;

        const mediaId = item.dataset.mediaId;
        const thumbUrl = item.dataset.thumbUrl;
        const altText = item.dataset.altText || '';
        selectImage(currentImagePicker, mediaId, thumbUrl, altText);
        closeImagePickerModal();
    });

    return modal;
}

function openImagePickerModal(picker) {
    currentImagePicker = picker;
    pickerActiveFolder = '';
    pickerActiveTags = [];
    const modal = getImagePickerModal();
    modal.classList.add('open');
    document.body.style.overflow = 'hidden';

    // Reset search
    const searchInput = modal.querySelector('.image-picker-modal-search input');
    searchInput.value = '';

    // Load media items
    loadMediaItems('');

    // Focus search
    setTimeout(() => searchInput.focus(), 100);
}

function closeImagePickerModal() {
    if (imagePickerModal) {
        imagePickerModal.classList.remove('open');
        document.body.style.overflow = '';
        currentImagePicker = null;

        // Clear selection
        const selectBtn = imagePickerModal.querySelector('[data-action="select"]');
        selectBtn.disabled = true;
        imagePickerModal.querySelectorAll('.image-picker-modal-item.selected').forEach(i => {
            i.classList.remove('selected');
        });
    }
}

function buildFolderTree(folders) {
    // Build parent-child map
    const byParent = {};
    folders.forEach(f => {
        const pid = f.parent_id || '';
        if (!byParent[pid]) byParent[pid] = [];
        byParent[pid].push(f);
    });

    function renderLevel(parentId, depth) {
        const children = byParent[parentId] || [];
        return children.map(f => {
            const isActive = f.id === pickerActiveFolder;
            const indent = depth > 0 ? ` style="padding-left: ${depth * 1.25}rem"` : '';
            const subfolders = renderLevel(f.id, depth + 1);
            return `
                <li class="image-picker-modal-folder${isActive ? ' active' : ''}"${indent} data-folder-id="${f.id}">
                    <svg class="icon icon-sm" viewBox="0 0 24 24" fill="none"><path d="M13 7L11.8845 4.76892C11.5634 4.1268 11.4029 3.80573 11.1634 3.57116C10.9516 3.36373 10.6963 3.20597 10.4161 3.10931C10.0992 3 9.74021 3 9.02229 3H5.2C4.0799 3 3.51984 3 3.09202 3.21799C2.71569 3.40973 2.40973 3.71569 2.21799 4.09202C2 4.51984 2 5.0799 2 6.2V7M2 7H17.2C18.8802 7 19.7202 7 20.362 7.32698C20.9265 7.6146 21.3854 8.07354 21.673 8.63803C22 9.27976 22 10.1198 22 11.8V16.2C22 17.8802 22 18.7202 21.673 19.362C21.3854 19.9265 20.9265 20.3854 20.362 20.673C19.7202 21 18.8802 21 17.2 21H6.8C5.11984 21 4.27976 21 3.63803 20.673C3.07354 20.3854 2.6146 19.9265 2.32698 19.362C2 18.7202 2 17.8802 2 16.2V7Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>
                    <span class="image-picker-modal-folder-name">${f.name}</span>
                    <span class="image-picker-modal-folder-count">${f.count}</span>
                </li>
                ${subfolders}
            `;
        }).join('');
    }

    return renderLevel('', 0);
}

function loadMediaItems(search) {
    const modal = getImagePickerModal();
    const grid = modal.querySelector('.image-picker-modal-grid');
    const selectBtn = modal.querySelector('[data-action="select"]');
    const foldersContainer = modal.querySelector('.image-picker-modal-folders');
    const tagsContainer = modal.querySelector('.image-picker-modal-tags');
    const infoContainer = modal.querySelector('.image-picker-modal-info');

    grid.innerHTML = '<div class="image-picker-modal-loading">Loading...</div>';
    selectBtn.disabled = true;

    // Build URL with filters
    const params = new URLSearchParams();
    if (search) params.set('search', search);
    if (pickerActiveFolder) params.set('folder', pickerActiveFolder);
    pickerActiveTags.forEach(t => params.append('tag', t));

    let url = '/admin/media/picker/list';
    if (params.toString()) url += '?' + params.toString();

    fetch(url)
        .then(res => res.json())
        .then(data => {
            // Render folders sidebar
            if (data.folders && data.folders.length > 0) {
                foldersContainer.innerHTML = buildFolderTree(data.folders);
            } else {
                foldersContainer.innerHTML = '<li class="image-picker-modal-empty-hint">No folders</li>';
            }

            // Render tags sidebar
            if (data.tags && data.tags.length > 0) {
                tagsContainer.innerHTML = data.tags.map(tag => {
                    const isActive = pickerActiveTags.includes(tag.id);
                    return `<button type="button" class="image-picker-modal-tag${isActive ? ' active' : ''}" data-tag-id="${tag.id}">
                        ${tag.name}
                        <span class="image-picker-modal-tag-count">${tag.count}</span>
                    </button>`;
                }).join('');
            } else {
                tagsContainer.innerHTML = '<span class="image-picker-modal-empty-hint">No tags</span>';
            }

            // Update info
            infoContainer.textContent = data.items ? `${data.items.length} items` : '';

            // Render grid
            if (!data.items || data.items.length === 0) {
                grid.innerHTML = `
                    <div class="image-picker-modal-empty">
                        <svg class="icon" viewBox="0 0 24 24" fill="none"><path d="M4 16L8.58579 11.4142C9.36683 10.6332 10.6332 10.6332 11.4142 11.4142L16 16M14 14L15.5858 12.4142C16.3668 11.6332 17.6332 11.6332 18.4142 12.4142L20 14M14 8H14.01M6 20H18C19.1046 20 20 19.1046 20 18V6C20 4.89543 19.1046 4 18 4H6C4.89543 4 4 4.89543 4 6V18C4 19.1046 4.89543 20 6 20Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>
                        <span>No images found</span>
                    </div>
                `;
                return;
            }

            grid.innerHTML = data.items.map(item => `
                <button type="button" class="image-picker-modal-item"
                        data-media-id="${item.id}"
                        data-thumb-url="${item.thumb_url}"
                        data-alt-text="${item.alt_text || ''}">
                    ${item.is_image
                        ? `<img src="${item.thumb_url}" alt="${item.alt_text || item.filename}" loading="lazy" />`
                        : `<div class="image-picker-modal-item-icon">
                            <svg class="icon" viewBox="0 0 24 24" fill="none"><path d="M14 2.26946V6.4C14 6.96005 14 7.24008 14.109 7.45399C14.2049 7.64215 14.3578 7.79513 14.546 7.89101C14.7599 8 15.0399 8 15.6 8H19.7305M20 9.98822V17.2C20 18.8802 20 19.7202 19.673 20.362C19.3854 20.9265 18.9265 21.3854 18.362 21.673C17.7202 22 16.8802 22 15.2 22H8.8C7.11984 22 6.27976 22 5.63803 21.673C5.07354 21.3854 4.6146 20.9265 4.32698 20.362C4 19.7202 4 18.8802 4 17.2V6.8C4 5.11984 4 4.27976 4.32698 3.63803C4.6146 3.07354 5.07354 2.6146 5.63803 2.32698C6.27976 2 7.11984 2 8.8 2H12.0118C12.7455 2 13.1124 2 13.4577 2.08289C13.7638 2.15638 14.0564 2.27759 14.3249 2.44208C14.6276 2.6276 14.887 2.88703 15.4059 3.40589L18.5941 6.59411C19.113 7.11297 19.3724 7.3724 19.5579 7.67515C19.7224 7.94356 19.8436 8.2362 19.9171 8.5423C20 8.88757 20 9.25445 20 9.98822Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>
                           </div>`
                    }
                    <div class="image-picker-modal-item-name">${item.filename}</div>
                </button>
            `).join('');
        })
        .catch(err => {
            console.error('Failed to load media:', err);
            grid.innerHTML = '<div class="image-picker-modal-empty"><span>Failed to load media</span></div>';
        });
}

function selectImage(picker, mediaId, thumbUrl, altText) {
    const hidden = picker.querySelector('[data-publr-part="value"]');
    const preview = picker.querySelector('[data-publr-part="preview"]');
    const alt = picker.querySelector('[data-publr-part="alt"]');
    const trigger = picker.querySelector('[data-publr-part="trigger"]');
    const remove = picker.querySelector('[data-publr-part="remove"]');

    // Update hidden input
    if (hidden) hidden.value = mediaId;

    // Update preview
    if (preview) {
        preview.innerHTML = `<img src="${thumbUrl}" alt="${altText}" class="image-picker-thumb" />`;
    }

    // Update alt text display
    if (alt) {
        alt.textContent = altText ? `Alt: ${altText}` : '';
    }

    // Update state and button text
    picker.dataset.publrState = 'selected';
    if (trigger) trigger.textContent = 'Change Image';
    if (remove) remove.classList.remove('hidden');
}

function clearImage(picker) {
    const hidden = picker.querySelector('[data-publr-part="value"]');
    const preview = picker.querySelector('[data-publr-part="preview"]');
    const alt = picker.querySelector('[data-publr-part="alt"]');
    const trigger = picker.querySelector('[data-publr-part="trigger"]');
    const remove = picker.querySelector('[data-publr-part="remove"]');

    // Clear hidden input
    if (hidden) hidden.value = '';

    // Reset preview
    if (preview) {
        preview.innerHTML = `
            <div class="image-picker-placeholder">
                <svg class="icon" viewBox="0 0 24 24" fill="none"><path d="M4 16L8.58579 11.4142C9.36683 10.6332 10.6332 10.6332 11.4142 11.4142L16 16M14 14L15.5858 12.4142C16.3668 11.6332 17.6332 11.6332 18.4142 12.4142L20 14M14 8H14.01M6 20H18C19.1046 20 20 19.1046 20 18V6C20 4.89543 19.1046 4 18 4H6C4.89543 4 4 4.89543 4 6V18C4 19.1046 4.89543 20 6 20Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>
                <span>No image selected</span>
            </div>
        `;
    }

    // Clear alt text
    if (alt) alt.textContent = '';

    // Update state and button text
    picker.dataset.publrState = 'empty';
    if (trigger) trigger.textContent = 'Select Image';
    if (remove) remove.classList.add('hidden');
}

register('image-picker', (el) => {
    const trigger = el.querySelector('[data-publr-part="trigger"]');
    const removeBtn = el.querySelector('[data-publr-part="remove"]');

    if (trigger) {
        trigger.addEventListener('click', () => {
            openImagePickerModal(el);
        });
    }

    if (removeBtn) {
        removeBtn.addEventListener('click', () => {
            clearImage(el);
        });
    }
});
