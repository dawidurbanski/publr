// Publr Interactivity — Dismiss
// Click-outside and Escape key handling for open components.
// Cleanup (unportal, release focus) is handled by _publrOnClose callbacks set by each handler.

import { openStack, close } from './toggle.js';

// Click outside — close open components
document.addEventListener('mousedown', (e) => {
    if (!openStack.length) return;
    for (let i = openStack.length - 1; i >= 0; i--) {
        const root = openStack[i];
        // Use stored ref — querySelector fails when content is portaled out of root
        const content = root._publrContent || root.querySelector('[data-publr-part="content"]');
        if (root.contains(e.target) || (content && content.contains(e.target))) continue;
        close(root);
    }
});

// Escape key — close topmost open component
document.addEventListener('keydown', (e) => {
    if (e.key !== 'Escape' || !openStack.length) return;
    const root = openStack[openStack.length - 1];
    const type = root.dataset.publrComponent;
    if (type === 'dialog' && root.dataset.publrDismissable === 'false') return;
    close(root);
});
