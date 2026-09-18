/** LANraragi lifecycle adapter. Loading, decoding and Blob URLs remain loader-owned. */
import { ReaderSlideController } from "lrr-reader-slide-controller";

export function normalizeSlideDuration(value) {
    const number = Number(value);
    return Number.isFinite(number) && number > 0 ? Math.max(50, Math.min(1000, Math.round(number / 25) * 25)) : 200;
}

export function createReaderSlide({ element, duration, read, loadNeighbors, navigate }) {
    const engine = new ReaderSlideController();
    engine.duration = normalizeSlideDuration(duration);
    const effects = document.createElement("div");
    effects.className = "reader-slide-effects";
    effects.setAttribute("aria-hidden", "true");
    element.append(effects);
    element.setAttribute("data-reader-slide", "");
    engine.retire = (image) => { if (image.parentElement === effects) image.remove(); };
    let generation = 0;
    let adjacent = [];
    let drag;
    let touchNavigation = false;
    let ignoreClickUntil = 0;
    let disposed = false;
    const pointers = new Set();
    const readImages = () => read().filter(image => image.complete && image.naturalWidth)
        .map(image => ({ image, rect: image.getBoundingClientRect() }))
        .filter(({ rect }) => rect.width > 0 && rect.height > 0);
    const eligible = () => {
        const entries = engine.images;
        return entries.length > 0 && (window.visualViewport?.scale ?? 1) <= 1.01 && entries.every(({ rect }) =>
            rect.left >= -2 && rect.right <= innerWidth + 2 && rect.top >= -2 && rect.bottom <= innerHeight + 2);
    };
    const resetPointer = () => {
        const id = drag?.id;
        drag = undefined;
        if (id !== undefined && element.hasPointerCapture(id)) element.releasePointerCapture(id);
    };
    const reset = () => {
        generation += 1;
        resetPointer();
        pointers.clear();
        touchNavigation = false;
        engine.clear();
        effects.replaceChildren();
        adjacent = [];
        element.removeAttribute("data-reader-swipe");
    };
    const refresh = () => {
        if (disposed) return;
        if (!engine.busy) engine.refresh(readImages());
        element.toggleAttribute("data-reader-swipe", eligible());
    };
    const prepare = async () => {
        generation += 1;
        const token = generation;
        adjacent = [];
        refresh();
        if (!eligible()) return;
        try {
            const neighbors = await loadNeighbors();
            if (disposed || token !== generation || drag) return;
            adjacent = neighbors;
        } catch { /* Failed previews leave ordinary decoded navigation available. */ }
    };
    const measureNeighbors = () => {
        const current = engine.images;
        if (!current.length) return [];
        const left = Math.min(...current.map(e => e.rect.left));
        const right = Math.max(...current.map(e => e.rect.right));
        const top = Math.min(...current.map(e => e.rect.top));
        const bottom = Math.max(...current.map(e => e.rect.bottom));
        return adjacent.map(({ images, direction }) => {
            // Measure in a temporary copy of the real flex layout. Never reparent a live slot.
            if (images.some(image => read().includes(image))) return { images: [], direction };
            const box = document.createElement("div");
            box.style.cssText = `position:fixed;left:0;top:0;display:flex;justify-content:center;width:${element.getBoundingClientRect().width}px;visibility:hidden;pointer-events:none`;
            effects.append(box);
            const measured = images.map(image => {
                image.removeAttribute("id");
                image.className = "reader-image";
                image.style.cssText = read()[0]?.style.cssText || "";
                box.append(image);
                const frame = { display: "block" };
                const animation = image.animate([frame, frame], { duration: 1, fill: "both" });
                animation.pause();
                animation.currentTime = 0;
                return { image, animation };
            });
            const rects = measured.map(({ image }) => image.getBoundingClientRect());
            measured.forEach(({ image, animation }) => { animation.cancel(); effects.append(image); });
            box.remove();
            const width = rects.reduce((sum, rect) => sum + rect.width, 0);
            let x = (left + right - width) / 2;
            return { direction, images: measured.map(({ image }, index) => {
                const rect = rects[index];
                const positioned = new DOMRect(x, (top + bottom - rect.height) / 2, rect.width, rect.height);
                x += rect.width;
                return { image, rect: positioned };
            }).filter(({ rect }) => rect.width > 0 && rect.height > 0) };
        });
    };
    const velocity = now => {
        const samples = drag?.samples || [];
        const last = samples.at(-1);
        const first = samples.find(sample => now - sample.time <= 80) || last;
        return last && first && now - last.time < 80 && last.time > first.time
            ? (last.x - first.x) / (last.time - first.time) : 0;
    };
    const down = event => {
        if (!["touch", "pen"].includes(event.pointerType)) return;
        pointers.add(event.pointerId);
        if (pointers.size > 1 || !event.isPrimary) {
            if (drag?.active) engine.release(0);
            resetPointer();
            return;
        }
        if (!eligible() || event.target.closest(".absolute-options, button, a[href], input, select, textarea, [role=slider]")) return;
        const entries = engine.images;
        drag = { id: event.pointerId, x: event.clientX, y: event.clientY, active: false, offset: 0,
            width: Math.max(...entries.map(e => e.rect.right)) - Math.min(...entries.map(e => e.rect.left)),
            samples: [{ x: event.clientX, time: event.timeStamp }] };
    };
    const move = event => {
        if (!drag || drag.id !== event.pointerId || pointers.size !== 1) return;
        const dx = event.clientX - drag.x;
        const dy = event.clientY - drag.y;
        if (!drag.active) {
            if (Math.abs(dy) > 8 && Math.abs(dy) >= Math.abs(dx)) { resetPointer(); return; }
            if (Math.abs(dx) <= 8 || Math.abs(dx) <= Math.abs(dy) * 1.2) return;
            engine.beginDrag(measureNeighbors());
            drag.active = true;
            element.setPointerCapture(event.pointerId);
        }
        event.preventDefault();
        drag.samples.push({ x: event.clientX, time: event.timeStamp });
        drag.samples = drag.samples.filter(sample => event.timeStamp - sample.time <= 100);
        drag.offset = Math.max(-drag.width * 0.95, Math.min(drag.width * 0.95, dx));
        engine.moveDrag(drag.offset, velocity(event.timeStamp));
    };
    const up = event => {
        // Implicit capture moves from the child image to this viewer during a swipe.
        if (event.type === "lostpointercapture" && event.target !== element) return;
        pointers.delete(event.pointerId);
        if (!drag || drag.id !== event.pointerId) return;
        if (!drag.active) { resetPointer(); return; }
        const speed = event.type === "pointerup" ? velocity(event.timeStamp) : 0;
        const { offset, width } = drag;
        const commit = event.type === "pointerup" && (Math.abs(offset) > width * 0.2 || (Math.abs(speed) > 0.5 && Math.abs(offset) > 16));
        ignoreClickUntil = performance.now() + 400;
        resetPointer();
        engine.release(speed);
        if (commit) {
            touchNavigation = true;
            navigate(offset + speed * 100 < 0 ? 1 : -1);
        }
    };
    const click = event => {
        if (element.contains(event.target) && performance.now() < ignoreClickUntil && event.detail !== 0) {
            event.preventDefault();
            event.stopImmediatePropagation();
        }
    };
    const cancel = () => { reset(); refresh(); void prepare(); };
    const events = [["pointerdown", down], ["pointermove", move], ["pointerup", up],
        ["pointercancel", up], ["lostpointercapture", up]];
    events.forEach(([name, handler]) => element.addEventListener(name, handler, { capture: name === "click", passive: false }));
    document.addEventListener("click", click, true);
    window.addEventListener("resize", cancel);
    window.addEventListener("blur", cancel);
    window.addEventListener("pagehide", reset);
    void prepare();
    return {
        // Snapshot before replacement; mount detached outgoing nodes before measuring new layout.
        before() { refresh(); resetPointer(); },
        after(direction) {
            if (!direction) { cancel(); return; }
            for (const { image } of engine.images) if (!image.isConnected) {
                image.removeAttribute("id");
                effects.append(image);
            }
            engine.navigate(readImages, direction, touchNavigation);
            touchNavigation = false;
            void prepare();
        },
        decoded: (src) => [...read(), ...effects.querySelectorAll("img"), ...adjacent.flatMap(entry => entry.images)]
            .find(image => image.complete && image.naturalWidth && (image.currentSrc || image.src) === src),
        sources: () => [...effects.querySelectorAll("img"), ...adjacent.flatMap(entry => entry.images)].map(image => image.currentSrc || image.src),
        dispose() {
            disposed = true;
            reset();
            effects.remove();
            element.removeAttribute("data-reader-slide");
            events.forEach(([name, handler]) => element.removeEventListener(name, handler, name === "click"));
            document.removeEventListener("click", click, true);
            window.removeEventListener("resize", cancel);
            window.removeEventListener("blur", cancel);
            window.removeEventListener("pagehide", reset);
        },
    };
}
