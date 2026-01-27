// Publr Interactivity — Toggle
// Handles data-publr-state open/close toggling with aria-expanded sync.
(function() {
    'use strict';

    var publr = window.publr || {};
    var openStack = [];

    function open(root) {
        root.dataset.publrState = 'open';
        var trigger = root.querySelector('[data-publr-part="trigger"]');
        if (trigger) trigger.setAttribute('aria-expanded', 'true');
        openStack.push(root);
    }

    function close(root) {
        root.dataset.publrState = 'closed';
        var trigger = root.querySelector('[data-publr-part="trigger"]');
        if (trigger) trigger.setAttribute('aria-expanded', 'false');
        var idx = openStack.indexOf(root);
        if (idx !== -1) openStack.splice(idx, 1);
    }

    function toggle(root) {
        if (root.dataset.publrState === 'open') close(root);
        else open(root);
    }

    function isOpen(root) {
        return root.dataset.publrState === 'open';
    }

    publr.open = open;
    publr.close = close;
    publr.toggle = toggle;
    publr.isOpen = isOpen;
    publr.openStack = openStack;

    window.publr = publr;
})();
