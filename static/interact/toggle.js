// Publr Interactivity — Toggle
// Handles data-publr-state open/close toggling with aria-expanded sync.

export const openStack = [];

export function open(root) {
    root.dataset.publrState = 'open';
    const trigger = root.querySelector('[data-publr-part="trigger"]');
    if (trigger) trigger.setAttribute('aria-expanded', 'true');
    openStack.push(root);
}

export function close(root) {
    root.dataset.publrState = 'closed';
    const trigger = root.querySelector('[data-publr-part="trigger"]');
    if (trigger) trigger.setAttribute('aria-expanded', 'false');
    if (root._publrOnClose) {
        root._publrOnClose();
        root._publrOnClose = null;
    }
    const idx = openStack.indexOf(root);
    if (idx !== -1) openStack.splice(idx, 1);
}

export function toggle(root) {
    if (root.dataset.publrState === 'open') close(root);
    else open(root);
}

export function isOpen(root) {
    return root.dataset.publrState === 'open';
}
