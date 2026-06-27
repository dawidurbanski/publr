// Publr Interactivity — Entry Point
// Single module that loads the whole interactivity runtime. Every behavior
// registers through core (register / widget / delegate / feature), so it is
// idempotent and re-runs cleanly after an HMR swap (window.__publrReinit).

import { init } from './core.js';        // Registry + delegated-event engine
import './dismiss.js';        // Click-outside + Escape (delegated, bound once)
import './components.js';      // All component handlers
import './repeater.js';        // Repeater field widget
import './kv-picker.js';       // `$` variable picker (delegated)
import './admin-shell.js';     // Admin chrome: sidebar toggle + theme toggle
import '../admin.js';          // Admin page behaviors (media, forms, …)
import '../media-selection.js'; // Media library bulk selection
import './presence.js';        // Collaboration presence (entry form)

// Re-export for programmatic use
export { toast } from './components.js';
export { init };
