// Publr Interactivity — Core
// Shared registry and namespace. Loaded by admin and themes.
(function() {
    'use strict';

    var publr = window.publr || {};
    var handlers = publr.handlers || {};
    var features = publr.features || {};

    publr.handlers = handlers;
    publr.features = features;

    // Register a component handler (keyed by data-publr-component value)
    publr.register = function(type, fn) {
        handlers[type] = fn;
    };

    // Register an interactivity feature (e.g. toggle, bind, fetch)
    publr.feature = function(name, fn) {
        features[name] = fn;
    };

    // Init: scan DOM for components, dispatch to handlers
    publr.init = function() {
        var components = document.querySelectorAll('[data-publr-component]');
        for (var i = 0; i < components.length; i++) {
            var el = components[i];
            var type = el.dataset.publrComponent;
            if (handlers[type]) handlers[type](el, publr);
        }
        // Run features
        for (var name in features) {
            if (features.hasOwnProperty(name)) features[name](publr);
        }
    };

    window.publr = publr;
    document.addEventListener('DOMContentLoaded', publr.init);
})();
