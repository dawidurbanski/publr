# PublrEditor (built-in block editor) — Build & Vendoring Procedure

Authoritative procedure for reproducing the files in this module's `vendor/` directory.

**Architecture note:** this core admin module registers PublrEditor (the
first-party block editor, `publr-editor/` in the parent workspace) as the
`"block"` editor — it is part of the core product, discovered through the same
module pass as the rest of `src/modules/admin/`. The editor registry, the
asset-serving route, and the default `"form"` editor live in `src/editors.zig`
and friends; third-party editors can still ship as plugins (same shape as
`plugins/gutenberg/`). A demo `article` content type that opts into this
editor lives in `plugins/publr-editor/`.

The edit page mounts the editor's **full harness** (`createEditorShell`) —
topbar, list view, inserter, block-settings sidebar, patterns explorer — and
plugs the CMS into its host seams: a Save action in the shell topbar, and an
"Entry" host panel that adopts the admin's server-rendered entry sidebar
(publish/discard, version history, releases). The shell is self-skinned (its
own dark tokens scoped to `#editor-shell`), so the admin theme cannot recolor
it.

**No npm runs inside `cms/`.** The bundle is built in `publr-editor/` (a
vite-plus project) and copied here as opaque pre-built artifacts.

## Reproduce

From the parent workspace root:

```bash
./scripts/vendor-editor.sh
```

That script runs `npm run build` in `publr-editor/` and copies:

| vendored file | source |
|---|---|
| `vendor/editor.js` | `publr-editor/dist/publr-editor.iife.js` |
| `vendor/editor.css` | `publr-editor/dist/publr-editor.css` |

and stamps `VERSION.txt` with the source commit. Re-run after any
`publr-editor/src/` change that should reach the CMS. **Never edit the
vendored files in place.**

## What the bundle contains

- The editor engine (wire-contract upcast/downcast, commit/undo, canvas).
- The 36-block core set + core patterns — registration is still an explicit
  `registerCoreBlocks()`/`registerCorePatterns()` call, made by this module's
  bootstrap script.
- The FULL harness (`createEditorShell` + its markup and skin) with host
  seams (`actions`, `panels`) — plus the inline chrome (floating toolbar,
  slash picker, `+` inserter). `editor.css` ships no preflight — it never
  resets the host page; the shell skin is scoped to `#editor-shell`.
- The vendored PublrJS runtime. The IIFE sets `window.Publr` on load. NOTE:
  the condition this bundling was predicated on has flipped — the admin
  layouts now ship the real runtime (`/static/scripts/publr-admin.js` →
  `/static/scripts/publr.js`), so edit pages carry two PublrJS copies. Switch the
  vendoring to the editor's HOST build (`npm run build:host` →
  `publr-editor.host.iife.js`), which excludes PublrJS and delegates to
  `window.Publr` — the opt-out exists exactly for this case. (The
  `/static/publr-core.js` widget initializer this note used to contrast
  against is retired, #471.)

## What it deliberately does NOT contain

- The JIT wasm CSS engine — authored utility classes (e.g. `text-3xl` from
  style controls) are stored but not compiled in the admin canvas in v0.
  Wiring the CMS JIT as the editor's `CssEngine` (it already speaks the
  `httpCssEngine` POST contract) is the follow-up (story #218's render slot).
- Media persistence — the editor's OPFS `/media/*` store is skipped. The
  bootstrap instead passes a **MediaAdapter** wired to the CMS media library:
  `upload()` posts the `media.upload_json` action (multipart + `_csrf` field,
  JSON record back; 10MB admin cap, width/height detected via stb_image on
  native — null on wasm), and `browse()` opens the admin media-picker modal
  through `window.PublrAdmin.pickMedia`. Media URLs serialize as ordinary
  `/media/<storage_key>` paths.
