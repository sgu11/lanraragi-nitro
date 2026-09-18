/** Own reader image requests, decoded images and Blob URLs for one cache generation. */
export function createReaderImageLoader({
    fetchImage = (...args) => fetch(...args),
    makeImage = () => new Image(),
    urls = URL,
    getLimit = () => 8,
    getProtectedSources = () => new Set(),
    getDisplayedSources = () => new Set(),
    getRetainedSources = () => new Set(),
    maxDecoded = 2,
    maxDecodedBytes = Infinity,
} = {}) {
    const entries = new Map();
    const pending = new Map();
    const loading = new Map();
    const decoded = new Map();
    const probes = new Set();
    const dimensions = {};
    const sizes = {};
    let generation = 0;

    function assertCurrent(epoch) {
        if (epoch !== generation) throw new DOMException("Image request was superseded", "AbortError");
    }

    function release(src) {
        if (src?.startsWith("blob:") && ![...entries.values()].some((entry) => entry.src === src)) {
            urls.revokeObjectURL(src);
        }
    }

    function prune(retainKey) {
        pruneDecoded();
        const protectedSources = getProtectedSources();
        const displayed = getDisplayedSources();
        for (const [key, entry] of entries) {
            if (entries.size <= getLimit()) break;
            if (key === retainKey || loading.has(key) || protectedSources.has(key)
                || decoded.has(entry.src) || displayed.has(entry.src)) continue;
            entries.delete(key);
            release(entry.src);
        }
    }

    function pruneDecoded(retainSrc) {
        const protectedSources = new Set([...getDisplayedSources(), ...getRetainedSources()]);
        let total = [...decoded.values()].reduce((sum, entry) => sum + entry.bytes, 0);
        for (const [src, entry] of decoded) {
            if (decoded.size <= maxDecoded && total <= maxDecodedBytes) break;
            // In-flight promises must remain shared, even when they exceed the
            // budget temporarily. Current/previous display ownership wins too.
            if (!entry.settled || src === retainSrc || protectedSources.has(src)) continue;
            decoded.delete(src);
            total -= entry.bytes;
        }
    }

    function remember(key, entry) {
        entries.delete(key);
        entries.set(key, entry);
        prune(key);
        return entry;
    }

    function imageReady(src, epoch, priority = "low") {
        return new Promise((resolve, reject) => {
            const image = makeImage();
            image.decoding = "async";
            image.fetchPriority = priority;
            function finish(error) {
                probes.delete(cancel);
                image.onload = null;
                image.onerror = null;
                if (error) reject(error);
                else {
                    try { assertCurrent(epoch); resolve(image); } catch (err) { reject(err); }
                }
            }
            function cancel() {
                finish(new DOMException("Image request was superseded", "AbortError"));
                image.removeAttribute("src");
            }
            probes.add(cancel);
            image.onload = () => finish();
            image.onerror = () => finish(new Error(`Could not load ${src}`));
            image.src = src;
        });
    }

    async function bytes(index, src, { priority = "low" } = {}) {
        const epoch = generation;
        if (entries.has(src)) return remember(src, entries.get(src));
        let request = pending.get(src);
        if (!request) {
            const controller = new AbortController();
            request = { controller };
            request.promise = (async () => {
                const response = await fetchImage(src, { signal: controller.signal, priority });
                assertCurrent(epoch);
                if (!response.ok) throw new Error(`HTTP ${response.status}`);
                const blob = await response.blob();
                assertCurrent(epoch);
                sizes[index] = Math.round(blob.size / 1024);
                return remember(src, { src: urls.createObjectURL(blob), generation: epoch });
            })().finally(() => {
                if (pending.get(src) === request) pending.delete(src);
            });
            pending.set(src, request);
        }
        const entry = await request.promise;
        assertCurrent(epoch);
        return entry;
    }

    async function loadImage(index, src, strategy, priority) {
        const epoch = generation;
        if (strategy === "browser") {
            if (entries.has(src)) return remember(src, entries.get(src));
            let request = pending.get(src);
            if (!request) {
                request = {};
                request.promise = imageReady(src, epoch, priority).then((image) => {
                    dimensions[index] = { width: image.naturalWidth, height: image.naturalHeight };
                    // Do not retain decoded Image objects in the byte cache.
                    remember(src, { src, generation: epoch });
                    return { src, image, generation: epoch };
                }).finally(() => {
                    if (pending.get(src) === request) pending.delete(src);
                });
                pending.set(src, request);
            }
            const entry = await request.promise;
            assertCurrent(epoch);
            return entry;
        }
        const entry = await bytes(index, src, { priority });
        assertCurrent(epoch);
        if (dimensions[index]) return entry;
        const image = await imageReady(entry.src, epoch, priority);
        dimensions[index] = { width: image.naturalWidth, height: image.naturalHeight };
        return { ...entry, image };
    }

    function load(index, src, strategy = "blob", priority = "low") {
        if (loading.has(src)) return loading.get(src);
        // Pin bytes through the dimension probe, including navigation outside the
        // preload window. Concurrent callers share that probe as well as fetch.
        const promise = loadImage(index, src, strategy, priority).finally(() => {
            if (loading.get(src) === promise) loading.delete(src);
        });
        loading.set(src, promise);
        return promise;
    }

    async function decode(loaded) {
        const src = typeof loaded === "string" ? loaded : loaded?.src;
        if (!src) return;
        const epoch = loaded?.generation ?? generation;
        assertCurrent(epoch);
        let entry = decoded.get(src);
        if (!entry) {
            entry = { bytes: 0, settled: false, promise: null };
            const ready = loaded?.image ? Promise.resolve(loaded.image) : imageReady(src, epoch);
            // load fires before an async-decoding image is necessarily paintable.
            // Keep this promise so preloading and navigation share one decode.
            entry.promise = ready.then(async (image) => {
                assertCurrent(epoch);
                entry.bytes = (image.naturalWidth || 0) * (image.naturalHeight || 0) * 4;
                if (typeof image.decode === "function") await image.decode();
                assertCurrent(epoch);
                entry.settled = true;
                pruneDecoded(src);
                return image;
            }).catch((error) => {
                if (decoded.get(src) === entry) decoded.delete(src);
                throw error;
            });
        }
        decoded.delete(src);
        decoded.set(src, entry);
        pruneDecoded(src);
        const image = await entry.promise;
        assertCurrent(epoch);
        return image;
    }

    function alias(src, loaded) {
        assertCurrent(loaded.generation);
        remember(src, { src: loaded.src, generation });
        return loaded;
    }

    function invalidate() {
        generation += 1;
        for (const request of pending.values()) request.controller?.abort();
        pending.clear();
        loading.clear();
        for (const cancel of [...probes]) cancel();
        const owned = new Set([...entries.values()].map((entry) => entry.src));
        entries.clear();
        decoded.clear();
        for (const src of owned) release(src);
        for (const key of Object.keys(dimensions)) delete dimensions[key];
        for (const key of Object.keys(sizes)) delete sizes[key];
    }

    return { bytes, load, decode, alias, prune, invalidate, dispose: invalidate,
        dimensions, sizes, has: (src) => entries.has(src), generation: () => generation };
}

/** Bound speculative work across navigation generations; foreground loads bypass it. */
export function createReaderPreloadQueue({ concurrency = 2, pixelLimit = 16 * 1024 * 1024 } = {}) {
    const waiting = [];
    let active = 0;
    let activePixels = 0;

    function pump() {
        while (waiting.length) {
            const task = waiting[0];
            if (!task.isCurrent()) {
                waiting.shift();
                task.resolve();
                continue;
            }
            // One oversized image may run alone; it must not starve the queue.
            if (active >= concurrency || (active > 0 && activePixels + task.pixels > pixelLimit)) return;
            waiting.shift();
            active += 1;
            activePixels += task.pixels;
            Promise.resolve().then(() => task.isCurrent() ? task.run() : undefined)
                .then(task.resolve, task.reject)
                .finally(() => {
                    active -= 1;
                    activePixels -= task.pixels;
                    pump();
                });
        }
    }

    return {
        schedule(run, { pixels = pixelLimit, isCurrent = () => true } = {}) {
            return new Promise((resolve, reject) => {
                waiting.push({ run, pixels, isCurrent, resolve, reject });
                pump();
            });
        },
        clear() {
            for (const task of waiting.splice(0)) task.resolve();
        },
    };
}
