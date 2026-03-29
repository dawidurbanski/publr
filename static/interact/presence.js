// Publr Presence — real-time user presence on entry edit pages.
// Shows who else is viewing/editing the same entry.
// Depends on websocket.js for connection management.

import { send, on, off, connect, isConnected } from './websocket.js';

let currentEntryId = null;
let presenceContainer = null;
let activityTimer = null;
let heartbeatTimer = null;
let lastInputTime = Date.now();
let isActive = true;

const DEFAULT_INACTIVE_THRESHOLD = 60000; // 60s
const DEFAULT_HEARTBEAT_INTERVAL = 10000; // 10s
const MIN_INACTIVE_THRESHOLD = 250;
const MIN_HEARTBEAT_INTERVAL = 100;
const MIN_ACTIVITY_CHECK_INTERVAL = 100;

let inactiveThreshold = DEFAULT_INACTIVE_THRESHOLD;
let heartbeatInterval = DEFAULT_HEARTBEAT_INTERVAL;
let activityCheckInterval = DEFAULT_HEARTBEAT_INTERVAL;

// Current users on this entry (keyed by user_id)
const users = new Map();

// Field soft locks (keyed by field name)
const fieldLocks = new Map();
let focusedField = null;
let focusDebounceTimer = null;
let blurTimer = null;
let pendingBlurField = null;
const FOCUS_DEBOUNCE_MS = 75;

// Field edit broadcasting (debounced per field)
const editDebounceTimers = {};
const EDIT_DEBOUNCE_MS = 300;

// =========================================================================
// Init — called on edit pages
// =========================================================================

export function initPresence() {
    const form = document.getElementById('entry-form');
    if (!form) return;
    configureTiming(form);
    lastInputTime = Date.now();
    isActive = true;

    const entryId = form.dataset.entryId;
    if (!entryId) return;

    presenceContainer = document.getElementById('presence-users');
    if (!presenceContainer) return;

    currentEntryId = entryId;

    // Register WS message handlers
    on('presence_sync', handlePresenceSync);
    on('user_joined', handleUserJoined);
    on('user_left', handleUserLeft);
    on('user_activity', handleUserActivity);
    on('field_focused', handleFieldFocused);
    on('field_blurred', handleFieldBlurred);
    on('field_lock_invalidated', handleFieldLockInvalidated);
    on('lock_acquired', handleLockAcquired);
    on('lock_released', handleLockReleased);
    on('takeover_result', handleTakeoverResult);
    on('field_edit', handleFieldEdit);
    on('published_state', handlePublishedState);
    on('release_updated', handleReleaseUpdated);
    on('open', handleWsOpen);

    // Field focus/blur tracking (use focusin/focusout for event delegation)
    form.addEventListener('focusin', onFieldFocus);
    form.addEventListener('focusout', onFieldBlur);

    // Field edit broadcasting (debounced oninput + onchange for checkboxes)
    form.addEventListener('input', onFieldInput);
    form.addEventListener('change', onFieldChange);

    // Repeater structural sync (add/remove/reorder)
    form.addEventListener('publr:repeater-sync', onRepeaterSync);

    // Connect WS (idempotent if already connected)
    connect();

    // If already connected, subscribe immediately
    if (isConnected()) {
        sendSubscribe();
    }

    // Start activity detection
    startActivityDetection();

    // Start heartbeat
    heartbeatTimer = setInterval(sendHeartbeat, heartbeatInterval);

    // Clean up on page unload
    window.addEventListener('beforeunload', cleanup);
}

// =========================================================================
// WS event handlers
// =========================================================================

function handleWsOpen() {
    if (currentEntryId) {
        sendSubscribe();
    }
}

function handlePresenceSync(data) {
    if (!data || !data.users) return;
    users.clear();
    for (const user of data.users) {
        users.set(user.user_id, user);
    }
    renderPresence();

    // Apply field locks from sync (skip our own focused field)
    clearAllFieldLocks();
    if (data.locks) {
        for (const [field, lock] of Object.entries(data.locks)) {
            if (field === focusedField) continue;
            fieldLocks.set(field, lock);
            applyFieldLock(field, lock);
        }
    }

    // Re-acquire our focus if we had one (idempotent on server)
    if (focusedField) {
        send('focus', { field: focusedField });
    }

    // Set up takeover hover on page-load hard lock badges (includes repeater/group containers)
    const form = document.getElementById('entry-form');
    if (form) {
        form.querySelectorAll('.field-editor-badge.field-editor-active').forEach(function(badge) {
            var group = badge.closest('.form-group[data-field]');
            // Skip nested sub-field badges
            if (group && (group.closest('.field-repeater-item-content') || group.closest('.field-group-content'))) return;
            if (group) setupBadgeTakeoverHover(group, group.dataset.field);
        });
    }
}

function handleUserJoined(data) {
    if (!data || !data.user_id) return;
    users.set(data.user_id, data);
    renderPresence();
}

function handleUserLeft(data) {
    if (!data || !data.user_id) return;
    users.delete(data.user_id);
    renderPresence();
}

function handleUserActivity(data) {
    if (!data || !data.user_id) return;
    const user = users.get(data.user_id);
    if (user) {
        user.active = data.active;
        renderPresence();
    }
}

function handleFieldFocused(data) {
    if (!data || !data.field) return;

    // Track owner focus on hard-locked fields for takeover button visibility
    if (isHardLocked(data.field)) {
        const lock = fieldLocks.get(data.field);
        if (lock && lock.hard && lock.user_id === data.user_id) {
            lock.owner_focused = true;
            updateTakeoverButton(data.field);
        }
        return;
    }

    fieldLocks.set(data.field, data);
    applyFieldLock(data.field, data);
}

function handleFieldBlurred(data) {
    if (!data || !data.field) return;

    // Track owner blur on hard-locked fields for takeover button visibility
    if (isHardLocked(data.field)) {
        const lock = fieldLocks.get(data.field);
        if (lock && lock.hard && lock.user_id === data.user_id) {
            lock.owner_focused = false;
            updateTakeoverButton(data.field);
        }
        return;
    }

    fieldLocks.delete(data.field);
    removeFieldLock(data.field);
}

function handleFieldLockInvalidated(data) {
    if (!data || !data.field) return;

    // If we hold the lock, release it client-side
    if (focusedField === data.field) {
        focusedField = null;
        const group = document.querySelector('.form-group[data-field="' + data.field + '"]');
        if (group && group.contains(document.activeElement)) {
            document.activeElement.blur();
        }
    }

    fieldLocks.set(data.field, data);
    applyFieldLock(data.field, data);
}

function handleLockAcquired(data) {
    if (!data || !data.field) return;

    // If we hold the soft lock on this field, release it
    if (focusedField === data.field) {
        focusedField = null;
        const group = document.querySelector('.form-group[data-field="' + data.field + '"]');
        if (group && group.contains(document.activeElement)) {
            document.activeElement.blur();
        }
    }

    // Store as hard lock
    fieldLocks.set(data.field, { ...data, hard: true });
    applyFieldLock(data.field, { ...data, hard: true });

    // Trigger change detection (field value may have been updated by a prior field_edit)
    const form = document.getElementById('entry-form');
    if (form) form.dispatchEvent(new CustomEvent('publr:fields-updated'));
}

function handleLockReleased(data) {
    if (!data || !data.field) return;

    const existing = fieldLocks.get(data.field);
    if (existing && existing.hard) {
        fieldLocks.delete(data.field);
        removeFieldLock(data.field);
    }

    // Also clear page-load hard lock badges (field-editor-badge from initial render)
    const group = document.querySelector('.form-group[data-field="' + data.field + '"]');
    if (group) {
        const badge = group.querySelector('.field-editor-badge.field-editor-active');
        if (badge) {
            badge.classList.remove('field-editor-active');
            badge.innerHTML = '';
            // Re-enable inputs/buttons disabled by badge (not marked with data-soft-locked)
            group.querySelectorAll('input:disabled, textarea:disabled, select:disabled, button:disabled').forEach(function(el) {
                if (!el.dataset.softLocked) el.disabled = false;
            });
        }
    }

    // Trigger change detection (field may have reverted to published value)
    const form = document.getElementById('entry-form');
    if (form) form.dispatchEvent(new CustomEvent('publr:fields-updated'));
}

function handleFieldEdit(data) {
    if (!data || !data.field || data.value === undefined) return;

    const group = document.querySelector('.form-group[data-field="' + data.field + '"]');
    if (!group) {
        // May be a sub-field inside a repeater (e.g. "faq.0.question")
        const subGroup = document.querySelector('.form-group[data-field="' + data.field + '"]');
        if (subGroup) {
            const input = subGroup.querySelector('.form-control');
            if (input) input.value = data.value;
        }
        const form = document.getElementById('entry-form');
        if (form) form.dispatchEvent(new CustomEvent('publr:fields-updated'));
        return;
    }

    // Check if this is a repeater container field
    const repeater = group.querySelector('.field-repeater[data-field]');
    if (repeater) {
        // Parse JSON array and dispatch apply event to the repeater widget
        try {
            var items = JSON.parse(data.value);
            if (Array.isArray(items)) {
                repeater.dispatchEvent(new CustomEvent('publr:repeater-apply', {
                    detail: { items: items }
                }));
            }
        } catch(e) {}
        const form = document.getElementById('entry-form');
        if (form) form.dispatchEvent(new CustomEvent('publr:fields-updated'));
        return;
    }

    const input = group.querySelector('.form-control');
    if (input) {
        input.value = data.value;
    } else {
        // Boolean fields use checkbox
        const cb = group.querySelector('.form-check-input');
        if (cb) {
            cb.checked = (data.value === 'true' || data.value === '1');
        }
    }

    // Notify admin.js to re-run change detection (adds field-changed class)
    const form = document.getElementById('entry-form');
    if (form) form.dispatchEvent(new CustomEvent('publr:fields-updated'));
}

function handlePublishedState(data) {
    if (!data) return;
    const form = document.getElementById('entry-form');
    if (!form) return;
    form.dispatchEvent(new CustomEvent('publr:published-state', {
        detail: { publishedState: data.published_state, status: data.status }
    }));
}

function handleReleaseUpdated(data) {
    if (!data || !data.fields_in_releases) return;

    // Notify admin.js with the new release field data
    const form = document.getElementById('entry-form');
    if (form) {
        form.dispatchEvent(new CustomEvent('publr:release-updated', {
            detail: { fieldsInReleases: data.fields_in_releases }
        }));
    }
}

function handleTakeoverResult(data) {
    if (!data || !data.field) return;

    const group = document.querySelector('.form-group[data-field="' + data.field + '"]');
    if (!group) return;

    if (data.success) {
        // Takeover succeeded — remove lock, enable field
        fieldLocks.delete(data.field);
        removeFieldLock(data.field);

        // Also clear page-load hard lock badge
        const badge = group.querySelector('.field-editor-badge.field-editor-active');
        if (badge) {
            badge.classList.remove('field-editor-active');
            badge.innerHTML = '';
        }

        // Re-enable inputs/buttons
        group.querySelectorAll('input:disabled, textarea:disabled, select:disabled, button:disabled').forEach(function(el) {
            el.disabled = false;
            delete el.dataset.softLocked;
        });

        // Trigger change detection
        const form = document.getElementById('entry-form');
        if (form) form.dispatchEvent(new CustomEvent('publr:fields-updated'));
    } else {
        // Takeover blocked — show brief feedback
        showTakeoverFeedback(group, data.reason || 'Cannot take over this field');
    }
}

// =========================================================================
// Sending
// =========================================================================

function sendSubscribe() {
    send('subscribe', { entry_id: currentEntryId });
}

function sendHeartbeat() {
    send('heartbeat');
}

// =========================================================================
// Activity detection
// =========================================================================

function startActivityDetection() {
    const events = ['mousemove', 'keydown', 'touchstart', 'scroll'];
    for (const evt of events) {
        document.addEventListener(evt, onUserInput, { passive: true });
    }

    activityTimer = setInterval(checkActivity, activityCheckInterval);
}

function onUserInput() {
    lastInputTime = Date.now();
    if (!isActive) {
        isActive = true;
        send('activity', { active: true });
    }
}

function checkActivity() {
    if (isActive && (Date.now() - lastInputTime > inactiveThreshold)) {
        isActive = false;
        send('activity', { active: false });
    }
}

function configureTiming(form) {
    const lockTimeoutMs = parsePositiveInt(form.dataset.lockTimeoutMs);
    const heartbeatMs = parsePositiveInt(form.dataset.heartbeatIntervalMs);

    inactiveThreshold = Math.max(lockTimeoutMs ?? DEFAULT_INACTIVE_THRESHOLD, MIN_INACTIVE_THRESHOLD);
    heartbeatInterval = Math.max(heartbeatMs ?? DEFAULT_HEARTBEAT_INTERVAL, MIN_HEARTBEAT_INTERVAL);
    activityCheckInterval = deriveActivityCheckInterval(inactiveThreshold, heartbeatInterval);
}

function parsePositiveInt(value) {
    if (!value) return null;
    const parsed = Number.parseInt(value, 10);
    if (!Number.isFinite(parsed) || parsed <= 0) return null;
    return parsed;
}

function deriveActivityCheckInterval(inactiveMs, heartbeatMs) {
    const halfInactive = Math.max(Math.floor(inactiveMs / 2), MIN_ACTIVITY_CHECK_INTERVAL);
    return Math.min(heartbeatMs, halfInactive);
}

// =========================================================================
// Field focus/blur — soft lock events
// =========================================================================

// Resolve field name for presence tracking.
// Sub-fields inside repeaters/groups resolve to the top-level container field.
function resolveFieldName(target) {
    var formGroup = target.closest('.form-group[data-field]');
    if (!formGroup) return null;
    var nested = formGroup.closest('.field-repeater-item-content, .field-group-content');
    while (nested) {
        formGroup = nested.closest('.form-group[data-field]');
        if (!formGroup) return null;
        nested = formGroup.closest('.field-repeater-item-content, .field-group-content');
    }
    return formGroup.dataset.field;
}

function onFieldFocus(e) {
    // Ignore focus events caused by peek wrapper DOM mutations
    const form = document.getElementById('entry-form');
    if (form && form.dataset.peekMutating) return;

    // Ignore focus from peek buttons/values — they shouldn't trigger field locking
    if (e.target.closest('.field-peek-btn, .field-peek-value')) return;

    const field = resolveFieldName(e.target);
    if (!field) return;

    // Handle pending blur timer
    if (blurTimer) {
        clearTimeout(blurTimer);
        if (pendingBlurField !== field) {
            // Switching fields — flush blur for old field immediately
            send('blur', { field: pendingBlurField });
        }
        // Same field — cancel blur (intra-container tab)
        blurTimer = null;
        pendingBlurField = null;
    }

    if (field === focusedField) return;

    clearTimeout(focusDebounceTimer);
    focusedField = field;
    focusDebounceTimer = setTimeout(() => {
        send('focus', { field });
    }, FOCUS_DEBOUNCE_MS);
}

function onFieldBlur(e) {
    // Ignore blur events caused by peek wrapper DOM mutations
    const form = document.getElementById('entry-form');
    if (form && form.dataset.peekMutating) return;

    const field = resolveFieldName(e.target);
    if (!field) return;
    if (field !== focusedField) return;

    clearTimeout(focusDebounceTimer);
    // Debounce blur to absorb intra-container tabbing (repeaters/groups)
    clearTimeout(blurTimer);
    pendingBlurField = field;
    blurTimer = setTimeout(() => {
        if (focusedField === field) {
            focusedField = null;
            send('blur', { field });
        }
        blurTimer = null;
        pendingBlurField = null;
    }, FOCUS_DEBOUNCE_MS);
}

function onFieldInput(e) {
    if (!e.target.classList.contains('form-control')) return;
    const group = e.target.closest('.form-group[data-field]');
    if (!group) return;
    const field = group.dataset.field;

    // For sub-fields, check focus on the resolved container field
    const resolved = resolveFieldName(e.target);
    if (resolved !== focusedField) return;

    clearTimeout(editDebounceTimers[field]);
    editDebounceTimers[field] = setTimeout(() => {
        send('field_edit', { field, value: e.target.value });
    }, EDIT_DEBOUNCE_MS);
}

function onFieldChange(e) {
    if (!e.target.classList.contains('form-check-input')) return;
    const group = e.target.closest('.form-group[data-field]');
    if (!group) return;
    const field = group.dataset.field;

    const resolved = resolveFieldName(e.target);
    if (resolved !== focusedField) return;

    clearTimeout(editDebounceTimers[field]);
    editDebounceTimers[field] = setTimeout(() => {
        send('field_edit', { field, value: e.target.checked ? 'true' : 'false' });
    }, EDIT_DEBOUNCE_MS);
}

function onRepeaterSync(e) {
    if (!e.detail || !e.detail.field || !e.detail.items) return;
    // The repeater's container field must be our focused field
    const repeaterEl = e.target.closest('.field-repeater[data-field]');
    if (!repeaterEl) return;
    const resolved = resolveFieldName(repeaterEl);
    if (resolved !== focusedField) return;

    // Broadcast the full repeater state — use container field name for lock check
    send('field_edit', { field: resolved, value: JSON.stringify(e.detail.items) });
}

// =========================================================================
// Field lock UI — disable fields + show indicator
// =========================================================================

function applyFieldLock(field, lockData) {
    const group = document.querySelector('.form-group[data-field="' + field + '"]');
    if (!group) return;

    const isHard = lockData.hard === true;
    group.classList.remove('field-soft-locked', 'field-hard-locked');
    group.classList.add(isHard ? 'field-hard-locked' : 'field-soft-locked');

    // Disable inputs/buttons — only mark as soft-locked if not already disabled (e.g. by hard lock)
    // Skip peek buttons — they're read-only and should stay clickable on locked fields
    group.querySelectorAll('input, textarea, select, button').forEach(el => {
        if (el.classList.contains('field-peek-btn')) return;
        if (!el.disabled) {
            el.disabled = true;
            el.dataset.softLocked = 'true';
        }
    });

    // Add or update lock indicator
    let indicator = group.querySelector('.field-soft-lock-indicator');
    if (!indicator) {
        indicator = document.createElement('span');
        indicator.className = 'field-soft-lock-indicator';
        const checkRow = group.querySelector('.field-check-row');
        if (checkRow) {
            checkRow.prepend(indicator);
        }
    }

    const name = escapeAttr(lockData.name || '');
    const url = escapeAttr(lockData.avatar_url || '');
    if (isHard) {
        indicator.innerHTML = '<img src="' + url + '" class="field-editor-avatar" alt="" />'
            + 'Edited by ' + name;
        // Set up takeover hover interaction
        setupTakeoverHover(group, field);
    } else {
        indicator.innerHTML = '<img src="' + url + '" class="field-editor-avatar" alt="" />'
            + name + ' is editing';
    }
}

function removeFieldLock(field) {
    const group = document.querySelector('.form-group[data-field="' + field + '"]');
    if (!group) return;

    group.classList.remove('field-soft-locked', 'field-hard-locked');

    // Re-enable inputs
    group.querySelectorAll('[data-soft-locked="true"]').forEach(el => {
        el.disabled = false;
        delete el.dataset.softLocked;
    });

    // Remove indicator
    const indicator = group.querySelector('.field-soft-lock-indicator');
    if (indicator) indicator.remove();
}

// =========================================================================
// Takeover UI — hover interaction on hard-locked indicators
// =========================================================================

function setupTakeoverHover(group, field) {
    const indicator = group.querySelector('.field-soft-lock-indicator');
    if (!indicator || indicator.classList.contains('field-takeover-ready')) return;

    // Wrap existing content in a label span, append a takeover button.
    // CSS :hover swaps visibility — no DOM changes on hover, no size flicker.
    const label = document.createElement('span');
    label.className = 'field-lock-label';
    while (indicator.firstChild) label.appendChild(indicator.firstChild);
    indicator.appendChild(label);

    const btn = document.createElement('span');
    btn.className = 'field-takeover-btn';
    btn.textContent = 'Take over';
    indicator.appendChild(btn);

    indicator.classList.add('field-takeover-ready');

    btn.addEventListener('click', function(e) {
        e.preventDefault();
        e.stopPropagation();
        send('takeover', { field: field });
        btn.textContent = 'Taking over\u2026';
        btn.classList.add('field-takeover-pending');
    });
}

function setupBadgeTakeoverHover(group, field) {
    const badge = group.querySelector('.field-editor-badge.field-editor-active');
    if (!badge || badge.classList.contains('field-takeover-ready')) return;

    const label = document.createElement('span');
    label.className = 'field-lock-label';
    while (badge.firstChild) label.appendChild(badge.firstChild);
    badge.appendChild(label);

    const btn = document.createElement('span');
    btn.className = 'field-takeover-btn';
    btn.textContent = 'Take over';
    badge.appendChild(btn);

    badge.classList.add('field-takeover-ready');

    btn.addEventListener('click', function(e) {
        e.preventDefault();
        e.stopPropagation();
        send('takeover', { field: field });
        btn.textContent = 'Taking over\u2026';
        btn.classList.add('field-takeover-pending');
    });
}

function updateTakeoverButton(field) {
    const group = document.querySelector('.form-group[data-field="' + field + '"]');
    if (!group) return;

    const lock = fieldLocks.get(field);
    const disabled = lock && lock.owner_focused;

    // Toggle disabled class — CSS handles the rest
    const indicator = group.querySelector('.field-soft-lock-indicator.field-takeover-ready');
    if (indicator) indicator.classList.toggle('field-takeover-disabled', !!disabled);

    const badge = group.querySelector('.field-editor-badge.field-takeover-ready');
    if (badge) badge.classList.toggle('field-takeover-disabled', !!disabled);
}

function showTakeoverFeedback(group, message) {
    // Show temporary feedback tooltip
    let feedback = group.querySelector('.field-takeover-feedback');
    if (!feedback) {
        feedback = document.createElement('span');
        feedback.className = 'field-takeover-feedback';
        const checkRow = group.querySelector('.field-check-row');
        if (checkRow) checkRow.appendChild(feedback);
        else return;
    }
    feedback.textContent = message;
    feedback.classList.add('field-takeover-feedback-visible');
    setTimeout(function() {
        feedback.classList.remove('field-takeover-feedback-visible');
        setTimeout(function() { if (feedback.parentNode) feedback.remove(); }, 300);
    }, 2500);
}

function isHardLocked(field) {
    // Check WebSocket-based hard lock (from lock_acquired message)
    const lock = fieldLocks.get(field);
    if (lock && lock.hard) return true;

    // Check page-render hard lock (field_editors badge from initial load)
    const group = document.querySelector('.form-group[data-field="' + field + '"]');
    if (group && group.querySelector('.field-editor-badge.field-editor-active')) return true;

    return false;
}

function clearAllFieldLocks() {
    for (const field of fieldLocks.keys()) {
        removeFieldLock(field);
    }
    fieldLocks.clear();
}

// =========================================================================
// Rendering — stacked avatars in .edit-nav
// =========================================================================

function renderPresence() {
    if (!presenceContainer) return;

    // Filter out current user (server includes them in sync)
    // We show all OTHER users; current user sees themselves in the top-bar avatar
    const others = [];
    for (const user of users.values()) {
        others.push(user);
    }

    if (others.length === 0) {
        presenceContainer.innerHTML = '';
        return;
    }

    const maxShow = 5;
    const shown = others.slice(0, maxShow);
    const overflow = others.length - maxShow;

    let html = '';
    for (const user of shown) {
        const inactiveClass = user.active === false ? ' presence-inactive' : '';
        const name = escapeAttr(user.name || '');
        const url = escapeAttr(user.avatar_url || '');
        html += '<img src="' + url + '" alt="" title="' + name + '"' +
            ' class="version-avatar version-avatar-stacked' + inactiveClass + '" />';
    }

    if (overflow > 0) {
        html += '<span class="version-avatar version-avatar-overflow">+' + overflow + '</span>';
    }

    presenceContainer.innerHTML = html;
}

function escapeAttr(s) {
    return s.replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;');
}

// =========================================================================
// Cleanup
// =========================================================================

function cleanup() {
    if (currentEntryId) {
        send('unsubscribe', { entry_id: currentEntryId });
    }

    if (activityTimer) clearInterval(activityTimer);
    if (heartbeatTimer) clearInterval(heartbeatTimer);
    clearTimeout(focusDebounceTimer);
    clearTimeout(blurTimer);

    off('presence_sync', handlePresenceSync);
    off('user_joined', handleUserJoined);
    off('user_left', handleUserLeft);
    off('user_activity', handleUserActivity);
    off('field_focused', handleFieldFocused);
    off('field_blurred', handleFieldBlurred);
    off('field_lock_invalidated', handleFieldLockInvalidated);
    off('lock_acquired', handleLockAcquired);
    off('lock_released', handleLockReleased);
    off('takeover_result', handleTakeoverResult);
    off('field_edit', handleFieldEdit);
    off('published_state', handlePublishedState);
    off('release_updated', handleReleaseUpdated);
    off('open', handleWsOpen);

    const form = document.getElementById('entry-form');
    if (form) {
        form.removeEventListener('focusin', onFieldFocus);
        form.removeEventListener('focusout', onFieldBlur);
        form.removeEventListener('input', onFieldInput);
        form.removeEventListener('change', onFieldChange);
        form.removeEventListener('publr:repeater-sync', onRepeaterSync);
    }

    for (const key of Object.keys(editDebounceTimers)) {
        clearTimeout(editDebounceTimers[key]);
        delete editDebounceTimers[key];
    }

    const events = ['mousemove', 'keydown', 'touchstart', 'scroll'];
    for (const evt of events) {
        document.removeEventListener(evt, onUserInput);
    }

    clearAllFieldLocks();
    users.clear();
    focusedField = null;
    currentEntryId = null;
}

// =========================================================================
// Auto-init on DOM ready
// =========================================================================

if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initPresence);
} else {
    initPresence();
}
