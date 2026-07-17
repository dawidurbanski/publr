// Image field — PublrJS store behind the image-picker form fields
// (src/views/components/fields/image.zsx and the posts sidebar's featured
// image). Each field is its own local:image-field island, so several can
// coexist on one form. `pick` opens the shared media-picker dialog via
// window.PublrAdmin.pickMedia (owned by /static/scripts/media-picker.js) and writes
// the result into the hidden input — with a bubbling change event so form
// dirty-tracking sees it; `clear` resets the field.
//
// The preview swap is DOM construction on purpose: thumb_url/alt_text are
// user-controlled and must never be interpolated into markup.

import { Publr } from '/static/scripts/publr.js';

Publr.store('image-field', () => {
    let el = null;
    const part = (name) => (el ? el.querySelector('[data-publr-part="' + name + '"]') : null);

    function setValue(id) {
        const hidden = part('value');
        if (hidden) {
            hidden.value = id;
            hidden.dispatchEvent(new Event('change', { bubbles: true }));
        }
    }

    function select(m) {
        setValue(m.id);

        const preview = part('preview');
        if (preview) {
            const img = document.createElement('img');
            img.src = m.thumb_url || '';
            img.alt = m.alt_text || '';
            img.className = 'image-picker-thumb block max-h-[200px] max-w-full object-contain';
            preview.replaceChildren(img);
        }

        const alt = part('alt');
        if (alt) alt.textContent = m.alt_text ? 'Alt: ' + m.alt_text : '';

        el.dataset.publrState = 'selected';
        const trigger = part('trigger');
        if (trigger) trigger.textContent = 'Change Image';
        // The JIT orders display utilities after `hidden`, so the two classes
        // must never coexist — swap them instead of toggling `hidden` alone.
        const remove = part('remove');
        if (remove) {
            remove.classList.remove('hidden');
            remove.classList.add('inline-flex');
        }
    }

    const actions = {
        pick: () => {
            const pickMedia = window.PublrAdmin && window.PublrAdmin.pickMedia;
            if (!pickMedia || !el) return;
            const hidden = part('value');
            pickMedia({
                accept: el.dataset.publrAccept || '',
                selectedId: hidden ? hidden.value : '',
            }).then((m) => {
                if (m && el) select(m);
            });
        },
        clear: () => {
            if (!el) return;
            setValue('');

            const preview = part('preview');
            if (preview) {
                // Static markup — mirrors the server-rendered empty state.
                preview.innerHTML = `
                    <div class="image-picker-placeholder flex flex-col items-center gap-2 p-4 text-muted-foreground">
                        <svg class="icon h-8 w-8 opacity-50" viewBox="0 0 24 24" fill="none"><path d="M4 16L8.58579 11.4142C9.36683 10.6332 10.6332 10.6332 11.4142 11.4142L16 16M14 14L15.5858 12.4142C16.3668 11.6332 17.6332 11.6332 18.4142 12.4142L20 14M14 8H14.01M6 20H18C19.1046 20 20 19.1046 20 18V6C20 4.89543 19.1046 4 18 4H6C4.89543 4 4 4.89543 4 6V18C4 19.1046 4.89543 20 6 20Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>
                        <span class="text-sm">No image selected</span>
                    </div>
                `;
            }

            const alt = part('alt');
            if (alt) alt.textContent = '';

            el.dataset.publrState = 'empty';
            const trigger = part('trigger');
            if (trigger) trigger.textContent = 'Select Image';
            const remove = part('remove');
            if (remove) {
                remove.classList.add('hidden');
                remove.classList.remove('inline-flex');
            }
        },
    };

    return {
        actions,
        setup: ({ el: root }) => {
            el = root;
            return () => { el = null; };
        },
    };
});
