/** Map display slots to archive pages independently of left-to-right layout. */
export function getReaderPageSlots(displayWindow, mangaMode = false) {
    if (!displayWindow) return [];
    const { start, end } = displayWindow;
    if (start === end) return [{ selector: "#img", page: start }];
    return [
        { selector: "#img", page: mangaMode ? end : start },
        { selector: "#img_doublepage", page: mangaMode ? start : end },
    ];
}

/** Move retained decoded Images together, including swaps between live slots. */
export function replaceReaderImages(updates, { document = globalThis.document, onImage = () => {} } = {}) {
    const slots = updates.map((update) => {
        const previous = document.querySelector(update.selector);
        if (!previous || !update.image) throw new Error(`Missing reader image slot ${update.selector}`);
        return { ...update, previous, placeholder: document.createComment(update.selector),
            id: previous.id, className: previous.className, alt: previous.alt,
            priority: previous.fetchPriority || "high", style: previous.style.cssText };
    });
    // Detach both old images before moving either retained image. Otherwise a
    // direction change removes the second target while replacing the first.
    for (const slot of slots) slot.previous.replaceWith(slot.placeholder);
    for (const slot of slots) {
        const { image } = slot;
        image.id = slot.id;
        image.className = slot.className;
        image.alt = slot.alt;
        image.fetchPriority = slot.priority;
        image.style.cssText = slot.style;
        image.dataset.filename = slot.filename || "";
        slot.placeholder.replaceWith(image);
        onImage(image);
    }
}
