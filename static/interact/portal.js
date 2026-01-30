// Publr Interactivity — Portal & Positioning
// Moves elements to a portal root and positions them near a trigger.

export const PORTALED = ['dropdown', 'select', 'popover', 'tooltip'];

let portalRoot = null;

export function getPortalRoot() {
    if (!portalRoot) {
        portalRoot = document.createElement('div');
        portalRoot.id = 'publr-portal';
        document.body.appendChild(portalRoot);
    }
    return portalRoot;
}

export function portal(el) {
    el._publrParent = el.parentNode;
    el._publrNext = el.nextSibling;
    getPortalRoot().appendChild(el);
}

export function unportal(el) {
    if (el._publrParent) {
        el._publrParent.insertBefore(el, el._publrNext || null);
        el._publrParent = null;
        el._publrNext = null;
    }
}

export function position(content, trigger) {
    const tr = trigger.getBoundingClientRect();
    const style = content.style;
    style.position = 'fixed';
    style.left = tr.left + 'px';
    style.top = tr.bottom + 4 + 'px';
    style.minWidth = tr.width + 'px';

    requestAnimationFrame(() => {
        const cr = content.getBoundingClientRect();
        if (cr.bottom > window.innerHeight) {
            style.top = (tr.top - cr.height - 4) + 'px';
        }
        if (cr.right > window.innerWidth) {
            style.left = (window.innerWidth - cr.width - 8) + 'px';
        }
    });
}
