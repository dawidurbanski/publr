// Presence — real-time user presence + field locks on entry edit pages
// (PublrJS store; #160, replaces interact/presence.js). The avatar stack in
// the edit top bar is the local:presence island (src/views/components/
// presence_users.zsx) rendering reactive state via @for; everything else —
// soft/hard field locks, takeover, focus/blur/edit broadcasting, activity +
// heartbeat — stays imperative over the server-rendered form, exactly like
// the legacy widget (schema fields are not client-templated).
//
// Transport is the shared ref-counted socket (/static/scripts/ws.js): setup()
// acquires a handle, teardown releases it — released handlers never fire, so
// messages can't land after navigation. (Re)subscribe rides the open handler.
//
// Contracts preserved verbatim (entry-editor.js + repeater.js depend on
// them): the publr:fields-updated / publr:published-state /
// publr:release-updated / publr:repeater-apply CustomEvents on the form, the
// publr:repeater-sync listener, focus/blur debounce timing, owner-focused
// takeover gating, nested field-name resolution, and the lock re-enable
// rules — clearing a soft lock only re-enables [data-soft-locked] controls,
// never ones the server disabled or a hard lock owns.

import { Publr } from '/static/scripts/publr.js';
import { acquire } from '/static/scripts/ws.js';

const DEFAULT_INACTIVE_THRESHOLD = 60000; // 60s
const DEFAULT_HEARTBEAT_INTERVAL = 10000; // 10s
const MIN_INACTIVE_THRESHOLD = 250;
const MIN_HEARTBEAT_INTERVAL = 100;
const MIN_ACTIVITY_CHECK_INTERVAL = 100;
const FOCUS_DEBOUNCE_MS = 75;
const EDIT_DEBOUNCE_MS = 300;
const MAX_AVATARS = 5;

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

Publr.store('presence', () => {
    // Avatar stack — the island's @for template binds these.
    const state = Publr.reactive({
        users: [],
        hasUsers: false,
        overflow: false,
        overflowText: '',
    });

    let wsHandle = null;
    let currentEntryId = null;
    let activityTimer = null;
    let heartbeatTimer = null;
    let lastInputTime = Date.now();
    let isActive = true;

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

    // Field edit broadcasting (debounced per field)
    const editDebounceTimers = {};

    function send(type, data) {
        if (wsHandle) wsHandle.send(type, data);
    }

    // =====================================================================
    // WS event handlers
    // =====================================================================

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

        // Refresh SOFT locks from sync; hard locks are kept — they're remote
        // OWNERSHIP the sync doesn't carry (server only syncs the soft
        // focus-lock map), so dropping them here would re-enable a
        // remotely-owned field after every reconnect. The cost is a possibly
        // stale hard lock if the release happened while we were disconnected
        // — conservative by design; takeover remains available.
        clearSoftFieldLocks();
        if (data.locks) {
            for (const [field, lock] of Object.entries(data.locks)) {
                if (field === focusedField) continue;
                // Hard ownership wins: the owner's own soft focus-lock rides
                // the sync for the same field — applying it would downgrade
                // a page-load badge or a hard lock persisted across a
                // remount to soft (and later fully unlock on owner blur).
                // Same routing the live field_focused handler uses.
                if (!lock.hard && isHardLocked(field)) continue;
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
            form.querySelectorAll('.field-editor-badge.field-editor-active').forEach(function (badge) {
                var group = badge.closest('.form-group[data-field]');
                // Skip nested sub-field badges
                if (group && (group.closest('.field-repeater-item-content') || group.closest('.field-group-content'))) return;
                if (group) setupBadgeTakeoverHover(group, group.dataset.field);
            });
            // Re-wire takeover on hard-lock indicators a previous instance
            // left standing (teardown unwires the dead handler but keeps the
            // lock UI — sync can't replay hard locks, see clearSoftFieldLocks).
            form.querySelectorAll('.form-group.field-hard-locked[data-field]').forEach(function (group) {
                setupTakeoverHover(group, group.dataset.field);
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
                badge.replaceChildren();
                // Re-enable inputs/buttons disabled by badge (not marked with data-soft-locked)
                group.querySelectorAll('input:disabled, textarea:disabled, select:disabled, button:disabled').forEach(function (el) {
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
            // Parse JSON array and dispatch apply event to the repeater store —
            // its applySync rebuilds WITHOUT dispatching change or another
            // repeater-sync, so remote applies don't echo or trip autosave.
            try {
                var items = JSON.parse(data.value);
                if (Array.isArray(items)) {
                    repeater.dispatchEvent(new CustomEvent('publr:repeater-apply', {
                        detail: { items: items },
                    }));
                }
            } catch (e) {}
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

        // Notify the entry-editor store to re-run change detection (field-changed)
        const form = document.getElementById('entry-form');
        if (form) form.dispatchEvent(new CustomEvent('publr:fields-updated'));
    }

    function handlePublishedState(data) {
        if (!data) return;
        const form = document.getElementById('entry-form');
        if (!form) return;
        form.dispatchEvent(new CustomEvent('publr:published-state', {
            detail: { publishedState: data.published_state, status: data.status },
        }));
    }

    function handleReleaseUpdated(data) {
        if (!data || !data.fields_in_releases) return;

        // Notify the entry-editor store with the new release field data
        const form = document.getElementById('entry-form');
        if (form) {
            form.dispatchEvent(new CustomEvent('publr:release-updated', {
                detail: { fieldsInReleases: data.fields_in_releases },
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
                badge.replaceChildren();
            }

            // Re-enable inputs/buttons
            group.querySelectorAll('input:disabled, textarea:disabled, select:disabled, button:disabled').forEach(function (el) {
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

    const messageHandlers = {
        presence_sync: handlePresenceSync,
        user_joined: handleUserJoined,
        user_left: handleUserLeft,
        user_activity: handleUserActivity,
        field_focused: handleFieldFocused,
        field_blurred: handleFieldBlurred,
        field_lock_invalidated: handleFieldLockInvalidated,
        lock_acquired: handleLockAcquired,
        lock_released: handleLockReleased,
        takeover_result: handleTakeoverResult,
        field_edit: handleFieldEdit,
        published_state: handlePublishedState,
        release_updated: handleReleaseUpdated,
    };

    // =====================================================================
    // Sending
    // =====================================================================

    function sendSubscribe() {
        send('subscribe', { entry_id: currentEntryId });
    }

    function sendHeartbeat() {
        send('heartbeat');
    }

    // =====================================================================
    // Activity detection
    // =====================================================================

    const activityEvents = ['mousemove', 'keydown', 'touchstart', 'scroll'];

    function startActivityDetection() {
        for (const evt of activityEvents) {
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

    // =====================================================================
    // Field focus/blur — soft lock events
    // =====================================================================

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

        // Ignore the group header: <summary> is natively focusable (the old
        // legend wasn't), and inside a repeater row it would resolve to the
        // container field and soft-lock it without any value being edited.
        if (e.target.closest('.field-group-legend')) return;

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

    // =====================================================================
    // Field lock UI — disable fields + show indicator
    // =====================================================================

    // Indicator content is DOM-constructed — name/avatar_url are remote-user
    // controlled and must never be interpolated into markup.
    function setIndicatorContent(indicator, lockData, isHard) {
        const img = document.createElement('img');
        img.src = lockData.avatar_url || '';
        img.alt = '';
        img.className = 'field-editor-avatar h-5 w-5 shrink-0 rounded-full';
        const name = lockData.name || '';
        const text = isHard ? 'Edited by ' + name : name + ' is editing';
        indicator.replaceChildren(img, document.createTextNode(text));
    }

    function applyFieldLock(field, lockData) {
        const group = document.querySelector('.form-group[data-field="' + field + '"]');
        if (!group) return;

        const isHard = lockData.hard === true;
        group.classList.remove('field-soft-locked', 'field-hard-locked', 'opacity-40', 'opacity-60');
        group.classList.add(isHard ? 'field-hard-locked' : 'field-soft-locked', isHard ? 'opacity-60' : 'opacity-40');

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
            indicator.className = 'field-soft-lock-indicator flex items-center gap-1 whitespace-nowrap text-xs';
            const checkRow = group.querySelector('.field-check-row');
            if (checkRow) {
                checkRow.prepend(indicator);
            }
        }
        indicator.classList.toggle('text-primary', isHard);
        indicator.classList.toggle('text-warning', !isHard);

        setIndicatorContent(indicator, lockData, isHard);
        if (isHard) {
            // Set up takeover hover interaction
            setupTakeoverHover(group, field);
        }
    }

    function removeFieldLock(field) {
        const group = document.querySelector('.form-group[data-field="' + field + '"]');
        if (!group) return;

        group.classList.remove('field-soft-locked', 'field-hard-locked', 'opacity-40', 'opacity-60');

        // Re-enable inputs — ONLY the ones this store disabled; controls the
        // server rendered disabled (or a hard-lock badge owns) stay disabled.
        group.querySelectorAll('[data-soft-locked="true"]').forEach(el => {
            el.disabled = false;
            delete el.dataset.softLocked;
        });

        // Remove indicator
        const indicator = group.querySelector('.field-soft-lock-indicator');
        if (indicator) indicator.remove();
    }

    // =====================================================================
    // Takeover UI — hover interaction on hard-locked indicators
    // =====================================================================

    function wireTakeoverButton(host, field) {
        // Wrap existing content in a label span, append a takeover button.
        // CSS :hover swaps visibility — no DOM changes on hover, no size flicker.
        const label = document.createElement('span');
        label.className = 'field-lock-label flex items-center gap-1 group-hover/takeover:invisible';
        while (host.firstChild) label.appendChild(host.firstChild);
        host.appendChild(label);

        const btn = document.createElement('span');
        btn.className = 'field-takeover-btn absolute inset-y-0 right-0 hidden items-center whitespace-nowrap text-xs font-medium text-primary group-hover/takeover:flex';
        btn.textContent = 'Take over';
        host.appendChild(btn);

        host.classList.add('field-takeover-ready', 'group/takeover', 'relative', 'cursor-pointer');

        btn.addEventListener('click', function (e) {
            e.preventDefault();
            e.stopPropagation();
            send('takeover', { field: field });
            btn.textContent = 'Taking over…';
            btn.classList.add('field-takeover-pending');
        });
    }

    function setupTakeoverHover(group, field) {
        const indicator = group.querySelector('.field-soft-lock-indicator');
        if (!indicator || indicator.classList.contains('field-takeover-ready')) return;
        wireTakeoverButton(indicator, field);
    }

    function setupBadgeTakeoverHover(group, field) {
        const badge = group.querySelector('.field-editor-badge.field-editor-active');
        if (!badge || badge.classList.contains('field-takeover-ready')) return;
        wireTakeoverButton(badge, field);
    }

    function updateTakeoverButton(field) {
        const group = document.querySelector('.form-group[data-field="' + field + '"]');
        if (!group) return;

        const lock = fieldLocks.get(field);
        const disabled = lock && lock.owner_focused;

        // Toggle disabled class — CSS handles the rest
        const indicator = group.querySelector('.field-soft-lock-indicator.field-takeover-ready');
        if (indicator) {
            indicator.classList.toggle('field-takeover-disabled', !!disabled);
            indicator.classList.toggle('pointer-events-none', !!disabled);
        }

        const badge = group.querySelector('.field-editor-badge.field-takeover-ready');
        if (badge) {
            badge.classList.toggle('field-takeover-disabled', !!disabled);
            badge.classList.toggle('pointer-events-none', !!disabled);
        }
    }

    function showTakeoverFeedback(group, message) {
        // Show temporary feedback tooltip
        let feedback = group.querySelector('.field-takeover-feedback');
        if (!feedback) {
            feedback = document.createElement('span');
            feedback.className = 'field-takeover-feedback text-xs text-warning opacity-0 transition-opacity';
            const checkRow = group.querySelector('.field-check-row');
            if (checkRow) checkRow.appendChild(feedback);
            else return;
        }
        feedback.textContent = message;
        feedback.classList.add('field-takeover-feedback-visible', 'opacity-100');
        setTimeout(function () {
            feedback.classList.remove('field-takeover-feedback-visible', 'opacity-100');
            setTimeout(function () { if (feedback.parentNode) feedback.remove(); }, 300);
        }, 2500);
    }

    function isHardLocked(field) {
        // Check WebSocket-based hard lock (from lock_acquired message)
        const lock = fieldLocks.get(field);
        if (lock && lock.hard) return true;

        // Check page-render hard lock (field_editors badge from initial load)
        // and hard-lock UI a previous store instance left in place (teardown
        // keeps hard locks — presence_sync can't replay them, only soft ones).
        const group = document.querySelector('.form-group[data-field="' + field + '"]');
        if (group && group.querySelector('.field-editor-badge.field-editor-active')) return true;
        if (group && group.classList.contains('field-hard-locked')) return true;

        return false;
    }

    // Clear only SOFT locks (UI + tracking); hard locks stay in both. Used
    // on every presence_sync (reconnect must not re-enable remotely-owned
    // fields) and on teardown, where the surviving .field-hard-locked class
    // is what lets the NEXT instance recognize the lock — isHardLocked()
    // checks it, since sync can't replay hard ownership.
    function clearSoftFieldLocks() {
        for (const [field, lock] of fieldLocks.entries()) {
            if (!lock.hard) {
                removeFieldLock(field);
                fieldLocks.delete(field);
            }
        }
    }

    // Detach takeover wiring from hosts that persist across a teardown
    // (page-load badges, kept hard-lock indicators): their click handlers
    // close over THIS instance's released transport handle and would send
    // nothing. Restoring the plain label lets the next instance re-wire a
    // live one on its first presence_sync.
    function unwireTakeover(host) {
        const btn = host.querySelector(':scope > .field-takeover-btn');
        if (btn) btn.remove();
        const label = host.querySelector(':scope > .field-lock-label');
        if (label) {
            while (label.firstChild) host.insertBefore(label.firstChild, label);
            label.remove();
        }
        host.classList.remove(
            'field-takeover-ready', 'group/takeover', 'relative', 'cursor-pointer',
            'field-takeover-disabled', 'pointer-events-none', 'field-takeover-pending',
        );
    }

    // =====================================================================
    // Rendering — stacked avatars via the island's @for template
    // =====================================================================

    function renderPresence() {
        // Server includes the current user in sync; all OTHER users are
        // shown here — you see yourself in the top-bar avatar.
        const others = [...users.values()];
        const shown = others.slice(0, MAX_AVATARS);
        const over = others.length - MAX_AVATARS;

        state.users = shown.map((user) => ({
            id: user.user_id,
            name: user.name || '',
            avatar_url: user.avatar_url || '',
            inactive: user.active === false,
        }));
        state.hasUsers = shown.length > 0;
        state.overflow = over > 0;
        state.overflowText = over > 0 ? '+' + over : '';
    }

    // =====================================================================
    // Lifecycle
    // =====================================================================

    return {
        state,
        setup: ({ el }) => {
            const form = document.getElementById('entry-form');
            if (!form) return undefined; // layout also hosts non-entry editors
            configureTiming(form);
            lastInputTime = Date.now();
            isActive = true;

            const entryId = form.dataset.entryId;
            if (!entryId) return undefined; // unsaved drafts have no channel
            currentEntryId = entryId;

            // Shared ref-counted transport: connects on first acquire; our
            // handlers go inert the moment we release, and stale messages
            // for a PREVIOUS entry can't arrive — the old instance released
            // before this one acquired.
            wsHandle = acquire({
                open: handleWsOpen,
                message: (type, data) => {
                    const handler = messageHandlers[type];
                    if (handler) handler(data);
                },
            });

            // Field focus/blur tracking (focusin/focusout bubble; focus/blur don't)
            form.addEventListener('focusin', onFieldFocus);
            form.addEventListener('focusout', onFieldBlur);

            // Field edit broadcasting (debounced oninput + onchange for checkboxes)
            form.addEventListener('input', onFieldInput);
            form.addEventListener('change', onFieldChange);

            // Repeater structural sync (add/remove/reorder)
            form.addEventListener('publr:repeater-sync', onRepeaterSync);

            // If already connected (another consumer holds the socket),
            // subscribe immediately; otherwise the open handler does it.
            if (wsHandle.isConnected()) {
                sendSubscribe();
            }

            // A remount (HMR swap) can find an input already focused — it
            // will never fire another focusin, so synthesize the focus now
            // or its edits would fail the focusedField gate and neither
            // lock nor broadcast until the user blurs and refocuses.
            if (document.activeElement && document.activeElement !== document.body
                && form.contains(document.activeElement)) {
                onFieldFocus({ target: document.activeElement });
            }

            startActivityDetection();
            heartbeatTimer = setInterval(sendHeartbeat, heartbeatInterval);

            let cleaned = false;
            const cleanup = () => {
                if (cleaned) return;
                cleaned = true;

                // Unsubscribe FIRST, over the still-held connection; the
                // transport lingers briefly after release so it flushes.
                if (currentEntryId) {
                    send('unsubscribe', { entry_id: currentEntryId });
                }

                clearInterval(activityTimer);
                clearInterval(heartbeatTimer);
                clearTimeout(focusDebounceTimer);
                clearTimeout(blurTimer);
                for (const key of Object.keys(editDebounceTimers)) {
                    clearTimeout(editDebounceTimers[key]);
                    delete editDebounceTimers[key];
                }

                form.removeEventListener('focusin', onFieldFocus);
                form.removeEventListener('focusout', onFieldBlur);
                form.removeEventListener('input', onFieldInput);
                form.removeEventListener('change', onFieldChange);
                form.removeEventListener('publr:repeater-sync', onRepeaterSync);
                for (const evt of activityEvents) {
                    document.removeEventListener(evt, onUserInput);
                }
                window.removeEventListener('beforeunload', cleanup);

                // Soft locks only — hard-lock UI must survive a remount
                // (sync can't replay it); its dead takeover wiring is
                // detached so the next instance re-wires a live one.
                clearSoftFieldLocks();
                document.querySelectorAll('.field-takeover-ready').forEach(unwireTakeover);
                users.clear();
                focusedField = null;
                currentEntryId = null;

                if (wsHandle) {
                    wsHandle.release();
                    wsHandle = null;
                }
            };

            window.addEventListener('beforeunload', cleanup);
            return cleanup;
        },
    };
});
