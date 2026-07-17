// Publr admin bootstrap — THE single runtime entry for the admin layouts
// (#147). One <script type="module" src="/static/scripts/publr-admin.js"> per layout
// replaces the former per-module tag stack. Import order: runtime first
// (sets window.Publr and schedules the initial hydrate on DOMContentLoaded),
// then store registrations — the whole module graph evaluates before
// DOMContentLoaded, so every shared store and local factory exists before
// the first hydrate pass.
//
// Page-scoped stores are NOT here by design — they load with their pages:
//   media-library.js   media list view's script tag
//   media-edit.js      media edit view's script tag
//   kv-picker.js       <KvPicker /> island's script tag
//   presence.js        <PresenceUsers /> island's script tag
//   entry-editor.js    layout_edit.zsx (edit chrome only)
//   recompile-bar.js   layout.zsx
//   ws.js              imported by presence.js (ref-counted transport)
//
// publr-tabs.js registers the namespaced 'ds-tabs' store (#147 resolved) —
// no collision with app-defined 'tabs' stores. Interop contract: the DS
// store owns trigger/panel activation; page stores listen for clicks on
// [data-publr-part="trigger"] or observe data-publr-state instead of
// re-activating panels themselves.

// Core runtime + addons
import '/static/scripts/publr.js';
import '/static/scripts/publr-position.js';
import '/static/scripts/publr-query.js';

// (The publr-core.js toggle scanner is retired — FieldGroup collapses via
// native <details>/<summary>, #471. data-publr-component attributes on DS
// markup are inert identification markers now; nothing scans them.)

// DS component stores
import '/static/scripts/publr-toast.js';
import '/static/scripts/publr-tooltip.js';
import '/static/scripts/publr-checkbox.js';
import '/static/scripts/publr-dialog.js';
import '/static/scripts/publr-drawer.js';
import '/static/scripts/publr-reference-field.js';
import '/static/scripts/publr-dropdown.js';
import '/static/scripts/publr-select.js';
import '/static/scripts/publr-popover.js';
import '/static/scripts/publr-radio-group.js';
import '/static/scripts/publr-switch.js';
import '/static/scripts/publr-tabs.js';

// App stores present on every admin page
import '/static/scripts/media-picker.js';
import '/static/scripts/image-field.js';
import '/static/scripts/repeater.js';

// Admin shell chrome (sidebar, theme, nav state)
import '/static/scripts/shell.js';
