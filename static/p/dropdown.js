// PublrJS dropdown behavior (#151) — pilot for the overlay components.
// Drives the DS DropdownMenu markup (@store="local:dropdown", @portal content,
// :showIf, onClick/onKeydown). One reactive `open` flag; portal is a core
// directive, positioning is the opt-in position plugin, keyboard nav lives here
// (component-level). Only shows/hides/positions server-rendered nodes — no HTML
// generated in JS.
//
// NOTE: behavior lives in CMS for the pilot. Its proper home is the DS component
// (src/components/dropdown/dropdown.js) once PublrJS is a shared vendored package
// (deferred #74); until then the CMS-absolute import paths below keep it working
// in the real admin.
import { Publr } from "/static/publr-interactivity.js";
import { position } from "/static/publr-interactivity-position.js";

Publr.store("dropdown", () => {
  const state = Publr.reactive({ open: false });
  let root = null;
  let trigger = null;
  let content = null;
  let detachDismiss = null;

  const items = () =>
    content
      ? [...content.querySelectorAll('[data-publr-part="item"]')].filter(
          (el) => !el.disabled && el.getAttribute("aria-disabled") !== "true",
        )
      : [];

  const focusItem = (list, i) => {
    list.forEach((el, j) => {
      el.tabIndex = j === i ? 0 : -1;
    });
    list[i]?.focus();
  };

  const refocusTrigger = () => {
    if (trigger && content && content.contains(document.activeElement)) {
      (trigger.querySelector("button") || trigger).focus();
    }
  };

  return {
    state,
    actions: {
      toggle: () => {
        state.open = !state.open;
      },
      openMenu: (_d, ctx) => {
        ctx.event.preventDefault();
        state.open = true;
      },
      close: () => {
        state.open = false;
      },
      navKeys: (_d, ctx) => {
        const e = ctx.event;
        const list = items();
        if (!list.length) return;
        const cur = list.indexOf(document.activeElement);
        switch (e.key) {
          case "ArrowDown":
            e.preventDefault();
            focusItem(list, cur < list.length - 1 ? cur + 1 : 0);
            break;
          case "ArrowUp":
            e.preventDefault();
            focusItem(list, cur > 0 ? cur - 1 : list.length - 1);
            break;
          case "Home":
            e.preventDefault();
            focusItem(list, 0);
            break;
          case "End":
            e.preventDefault();
            focusItem(list, list.length - 1);
            break;
          case "Enter":
          case " ":
            e.preventDefault();
            if (cur >= 0) {
              list[cur].click();
              state.open = false;
            }
            break;
          case "Escape":
          case "Tab":
            e.preventDefault();
            state.open = false;
            break;
          default:
            if (e.key.length === 1 && !e.ctrlKey && !e.metaKey && !e.altKey) {
              const ch = e.key.toLowerCase();
              const m = list.find((it) =>
                it.textContent.trim().toLowerCase().startsWith(ch),
              );
              if (m) focusItem(list, list.indexOf(m));
            }
        }
      },
      itemClick: (_d, ctx) => {
        const item = ctx.event.target.closest('[data-publr-part="item"]');
        if (item && !item.disabled && item.getAttribute("aria-disabled") !== "true") {
          state.open = false;
        }
      },
    },
    setup: ({ el }) => {
      root = el;
      trigger = el.querySelector('[data-publr-part="trigger"]');
      content = el.querySelector('[data-publr-part="content"]');

      Publr.effect(() => {
        if (state.open) {
          // Content is portaled + shown via :showIf; position after layout.
          requestAnimationFrame(() => {
            if (!state.open || !content || !trigger) return;
            position(content, trigger, { placement: "bottom-start", offset: 8 });
            const list = items();
            if (list.length) focusItem(list, 0);
          });
          if (!detachDismiss) {
            const onDown = (ev) => {
              if (
                !root.contains(ev.target) &&
                !(content && content.contains(ev.target))
              ) {
                state.open = false;
              }
            };
            document.addEventListener("mousedown", onDown, true);
            detachDismiss = () => {
              document.removeEventListener("mousedown", onDown, true);
              detachDismiss = null;
            };
          }
        } else {
          refocusTrigger();
          if (detachDismiss) detachDismiss();
        }
      });

      return () => {
        if (detachDismiss) detachDismiss();
      };
    },
  };
});
