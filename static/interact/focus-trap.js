// Publr Interactivity — Focus Trap
// Traps Tab/Shift+Tab within a container, restores focus on release.

const FOCUSABLE = 'button, [href], input, select, textarea, [tabindex]:not([tabindex="-1"])';
let prevFocus = null;

export function trapFocus(container) {
    prevFocus = document.activeElement;
    const focusable = container.querySelectorAll(FOCUSABLE);
    if (focusable.length) focusable[0].focus();

    container._publrTrap = (e) => {
        if (e.key !== 'Tab') return;
        const els = container.querySelectorAll(FOCUSABLE);
        if (!els.length) return;
        const first = els[0];
        const last = els[els.length - 1];
        if (e.shiftKey && document.activeElement === first) {
            e.preventDefault();
            last.focus();
        } else if (!e.shiftKey && document.activeElement === last) {
            e.preventDefault();
            first.focus();
        }
    };
    container.addEventListener('keydown', container._publrTrap);
}

export function releaseFocus(container) {
    if (container._publrTrap) {
        container.removeEventListener('keydown', container._publrTrap);
        container._publrTrap = null;
    }
    if (prevFocus) {
        prevFocus.focus();
        prevFocus = null;
    }
}
