// Publr Interactivity — Dismiss
// Click-outside and Escape key handling for open components.
// Cleanup (unportal, release focus) is handled by _publrOnClose callbacks set by each handler.
(function() {
    'use strict';

    var publr = window.publr || {};

    // Click outside — close open components
    document.addEventListener('mousedown', function(e) {
        var stack = publr.openStack;
        if (!stack || !stack.length) return;
        for (var i = stack.length - 1; i >= 0; i--) {
            var root = stack[i];
            var content = root.querySelector('[data-publr-part="content"]');
            if (root.contains(e.target) || (content && content.contains(e.target))) continue;
            publr.close(root);
        }
    });

    // Escape key — close topmost open component
    document.addEventListener('keydown', function(e) {
        var stack = publr.openStack;
        if (e.key !== 'Escape' || !stack || !stack.length) return;
        var root = stack[stack.length - 1];
        var type = root.dataset.publrComponent;
        if (type === 'dialog' && root.dataset.publrDismissable === 'false') return;
        publr.close(root);
    });
})();
