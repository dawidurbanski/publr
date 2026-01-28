// Publr Interactivity — Focus Trap
// Traps Tab/Shift+Tab within a container, restores focus on release.
(function() {
    'use strict';

    var publr = window.publr || {};
    var FOCUSABLE = 'button, [href], input, select, textarea, [tabindex]:not([tabindex="-1"])';
    var prevFocus = null;

    function trapFocus(container) {
        prevFocus = document.activeElement;
        var focusable = container.querySelectorAll(FOCUSABLE);
        if (focusable.length) focusable[0].focus();

        container._publrTrap = function(e) {
            if (e.key !== 'Tab') return;
            var els = container.querySelectorAll(FOCUSABLE);
            if (!els.length) return;
            var first = els[0], last = els[els.length - 1];
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

    function releaseFocus(container) {
        if (container._publrTrap) {
            container.removeEventListener('keydown', container._publrTrap);
            container._publrTrap = null;
        }
        if (prevFocus) {
            prevFocus.focus();
            prevFocus = null;
        }
    }

    publr.trapFocus = trapFocus;
    publr.releaseFocus = releaseFocus;

    window.publr = publr;
})();
