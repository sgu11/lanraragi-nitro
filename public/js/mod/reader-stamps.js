import { getReaderPageSlots } from "lrr-reader-display";

/** Own one displayed spread's stamps, responses and active drag listeners. */
export function createReaderStamps({ getState, getArchiveForPage, request,
    onError = () => {}, onChange = () => {}, setNavigationEnabled = () => {},
    document = globalThis.document }) {
    let generation = 0;
    let markers = [];
    let loadedKey = null;
    let cancelDrag = null;

    function view() {
        const state = getState();
        const slots = getReaderPageSlots(state.displayWindow, state.mangaMode).map((slot) => ({
            ...slot, ...getArchiveForPage(slot.page + 1),
        }));
        return { ...state, slots, key: JSON.stringify(slots) };
    }

    function current(snapshot) {
        const state = view();
        return snapshot.generation === generation && snapshot.key === state.key
            && state.visible && !state.infiniteScroll;
    }

    function hide() {
        cancelDrag?.();
        document.querySelectorAll(".marker").forEach((element) => element.remove());
    }

    function clear() {
        generation += 1;
        markers = [];
        loadedKey = null;
        hide();
    }

    function coordinates(image, event) {
        const rect = image.getBoundingClientRect();
        if (!rect.width || !rect.height) return null;
        return {
            x: Math.max(0, Math.min(100, (event.clientX - rect.left) * 100 / rect.width)),
            y: Math.max(0, Math.min(100, (event.clientY - rect.top) * 100 / rect.height)),
        };
    }

    function position(marker, image, point) {
        const rect = image.getBoundingClientRect();
        const parent = marker.offsetParent || document.documentElement;
        const origin = parent.getBoundingClientRect();
        marker.style.left = `${rect.left - origin.left - parent.clientLeft + parent.scrollLeft + point.x * rect.width / 100}px`;
        marker.style.top = `${rect.top - origin.top - parent.clientTop + parent.scrollTop + point.y * rect.height / 100}px`;
    }

    async function mutate(snapshot, endpoint, method) {
        try {
            await request(endpoint, method);
            if (current(snapshot)) {
                onChange();
                await refresh();
            }
            return true;
        } catch (error) {
            if (current(snapshot)) onError(error);
            return false;
        }
    }

    function startDrag(event, marker, image, data) {
        if (event.button !== 0) return;
        event.preventDefault();
        event.stopPropagation();
        cancelDrag?.();
        const snapshot = { generation, key: loadedKey };
        const previousSelection = document.body.style.userSelect;
        document.body.style.userSelect = "none";
        setNavigationEnabled(false);

        const move = (next) => {
            if (next.pointerId !== event.pointerId) return;
            if (!current(snapshot)) { cleanup(); return; }
            const point = coordinates(image, next);
            if (point) position(marker, image, point);
        };
        const finish = (next) => {
            if (next.pointerId !== event.pointerId) return;
            const point = coordinates(image, next);
            cleanup();
            if (!point || !current(snapshot)) return;
            const params = new URLSearchParams({ position: `${point.x},${point.y}` });
            mutate(snapshot, `/api/stamps/${encodeURIComponent(data.id)}?${params}`, "PUT")
                .then(() => { if (current(snapshot)) render(); });
        };
        function cleanup() {
            document.removeEventListener("pointermove", move);
            document.removeEventListener("pointerup", finish);
            document.removeEventListener("pointercancel", cleanup);
            document.body.style.userSelect = previousSelection;
            setNavigationEnabled(true);
            cancelDrag = null;
        }
        cancelDrag = cleanup;
        document.addEventListener("pointermove", move);
        document.addEventListener("pointerup", finish);
        document.addEventListener("pointercancel", cleanup);
    }

    function render() {
        hide();
        const state = view();
        if (!state.visible || state.infiniteScroll || state.fullscreen || state.key !== loadedKey) return;
        const display = document.getElementById("display");
        if (!display) return;
        for (const data of markers) {
            const image = document.querySelector(data.selector);
            if (!image) continue;
            const marker = document.createElement("div");
            marker.className = "marker marker-context-menu";
            marker.title = data.name;
            marker.dataset.stampId = data.id;
            display.appendChild(marker);
            position(marker, image, data);
            marker.addEventListener("click", (event) => { event.preventDefault(); event.stopPropagation(); });
            marker.addEventListener("pointerdown", (event) => startDrag(event, marker, image, data));
        }
    }

    async function refresh() {
        clear();
        const state = view();
        if (!state.visible || state.infiniteScroll) return;
        const snapshot = { generation, key: state.key };
        try {
            const results = await Promise.all(state.slots.map(async (slot) => {
                const data = await request(`/api/archives/${slot.arcId}/stamps/${slot.localPage}`, "GET");
                return data.result.map((stamp) => {
                    const [x, y] = stamp.position.split(",").map(Number);
                    return { ...slot, id: String(stamp.id), name: stamp.content, x, y };
                });
            }));
            if (!current(snapshot)) return;
            markers = results.flat();
            loadedKey = state.key;
            render();
        } catch (error) {
            if (current(snapshot)) onError(error);
        }
    }

    function capture(image, event) {
        const state = view();
        const slot = state.slots.find((entry) => entry.selector === `#${image.id}`);
        const point = coordinates(image, event);
        if (!slot || !point) return null;
        return { ...slot, ...point, generation, key: state.key };
    }

    function add(snapshot, name) {
        const params = new URLSearchParams({ position: `${snapshot.x},${snapshot.y}`, content: name });
        return mutate(snapshot, `/api/archives/${snapshot.arcId}/stamps/${snapshot.localPage}?${params}`, "PUT");
    }

    function get(id) {
        const marker = markers.find((entry) => entry.id === String(id));
        return marker ? { ...marker, generation, key: loadedKey } : null;
    }

    function edit(snapshot, name) {
        const params = new URLSearchParams({ content: name });
        return mutate(snapshot, `/api/stamps/${encodeURIComponent(snapshot.id)}?${params}`, "PUT");
    }

    function remove(snapshot) {
        return mutate(snapshot, `/api/stamps/${encodeURIComponent(snapshot.id)}`, "DELETE");
    }

    return { refresh, render, hide, clear, dispose: clear, capture, add, get, edit, remove };
}
