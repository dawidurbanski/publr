// Publr Interactivity — Entry Point
// Single import that loads all interactivity features.

import { init } from './core.js';       // Registry + auto-init on DOMContentLoaded
import './dismiss.js';    // Click-outside + Escape handlers
import './components.js'; // All component handlers
import './repeater.js';   // Repeater field widget

// Re-export for programmatic use
export { toast } from './components.js';
export { init };
