import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import test from "node:test";
import { createReaderPreloadQueue } from "../../public/js/mod/reader-image-loader.js";

const source = readFileSync(new URL("../../public/js/mod/reader_common.js", import.meta.url), "utf8");
const preloadSource = source.slice(source.indexOf("function estimatePredecodePixels("), source.indexOf("function prunePreloadedImages()"));
const drain = () => new Promise(resolve => setImmediate(resolve));
function harness() {
    const pending = [], decoded = [], bytes = [];
    const context = vm.createContext({
        readerCursor: { token: 1 }, currentPage: 3, maxPage: 30,
        preloadCount: 2, doublePageMode: true, MAX_PREDECODED_IMAGES: 2,
        MAX_PREDECODED_BYTES: 512 * 1024 * 1024,
        preloadDirection: 1, preloadedDimensions: {},
        preloadQueue: createReaderPreloadQueue(),
        predecodeSources: new Set(), imageLoader: { generation: () => 0 },
        localStorage: { getItem: () => null },
        getReaderPreloadStrategy: () => "blob", getSpreadState: () => ({}),
        getPageNavigationDestination: () => context.currentPage + 2,
        getDisplayWindow: page => ({ start: page, end: page + 1 }),
        getCurrentDisplayWindow: () => ({ start: context.currentPage, end: context.currentPage + 1 }),
        getReaderImageSource: index => `/page/${index}`,
        isCurrentNavigation: token => token === context.readerCursor.token,
        loadImage: (index, priority) => new Promise(resolve => pending.push({ index, priority, resolve })),
        decodeImage: loaded => { decoded.push(loaded); },
        preloadBlobBytesWithFallback: async index => { bytes.push(index); },
        prunePreloadedImages: () => {},
    });
    vm.runInContext(preloadSource, context);
    return { context, pending, decoded, bytes };
}

test("nearest decoding precedes distant byte warming in the bounded queue", async () => {
    const h = harness(); h.context.preloadImages(); await drain();
    assert.deepEqual(h.pending.map(p => p.index), [5, 6]);
    assert(h.pending.every(p => p.priority === "low"));
    assert.deepEqual([...h.context.predecodeSources].sort(), [1, 2, 3, 4, 5, 6, 7, 8].map(i => `/page/${i}`));
    assert.deepEqual(h.bytes, []);
    h.pending.forEach(p => p.resolve(p.index)); await drain();
    assert.deepEqual(h.decoded, [5, 6]);
    assert.deepEqual(h.bytes, [7, 8, 2, 1]);
});

test("backward navigation warms and decodes the preceding spread first", async () => {
    const h = harness(); h.context.preloadDirection = -1;
    h.context.preloadImages(); await drain();
    assert.deepEqual(h.pending.map(p => p.index), [2, 1]);
    assert.deepEqual(h.bytes, []);
    h.pending.forEach(p => p.resolve(p.index)); await drain();
    assert.deepEqual(h.bytes, [0, 5, 6]);
});

test("stale in-flight work skips decode and queued work follows the new window", async () => {
    const h = harness(); h.context.MAX_PREDECODED_IMAGES = 4;
    h.context.preloadQueue = createReaderPreloadQueue();
    h.context.preloadImages(); await drain();
    h.context.readerCursor.token++; h.context.currentPage = 15;
    h.context.preloadQueue.clear(); h.context.preloadImages();
    h.pending.slice(0, 2).forEach(p => p.resolve(p.index)); await drain();
    assert.deepEqual(h.decoded, []);
    assert.deepEqual(h.pending.map(p => p.index), [5, 6, 17, 18]);
    h.pending.slice(2).forEach(p => p.resolve(p.index)); await drain();
    assert.deepEqual(h.decoded, [17, 18]);
    assert.deepEqual(h.pending.slice(4).map(p => p.index), [19, 20]);
});

test("large images limit speculative pixel memory and fit within the four-task ceiling", async () => {
    const h = harness(); h.context.MAX_PREDECODED_IMAGES = 8; h.context.preloadCount = 8;
    h.context.preloadQueue = createReaderPreloadQueue({ concurrency: 4, pixelLimit: 128 * 1024 * 1024 });
    h.context.preloadedDimensions[3] = { width: 4441, height: 6213 };
    h.context.preloadImages(); await drain();
    assert.equal(h.pending.length, 4);
    h.pending.forEach(p => p.resolve(p.index)); await drain();
    assert.equal(h.pending.length, 4, "512 MiB admits four of these images");
    assert.deepEqual(h.decoded, [5, 6, 7, 8]);
});

test("newly discovered large dimensions cannot overrun the speculative budget", async () => {
    const h = harness(); h.context.MAX_PREDECODED_BYTES = 1000;
    h.context.preloadedDimensions[3] = { width: 10, height: 10 };
    h.context.preloadImages(); await drain();
    h.context.preloadedDimensions[5] = { width: 100, height: 100 };
    h.pending.forEach(p => p.resolve(p.index)); await drain();
    assert.deepEqual(h.decoded, [6]);
});

test("zero preload makes no speculative requests", () => {
    const h = harness(); h.context.preloadCount = 0; h.context.preloadImages();
    assert.equal(h.pending.length, 0); assert.equal(h.bytes.length, 0);
    assert.deepEqual([...h.context.predecodeSources], ["/page/3", "/page/4"]);
});

test("browser-cache strategy does not fetch duplicate blob copies", async () => {
    const h = harness(); h.context.getReaderPreloadStrategy = () => "browser";
    h.context.preloadImages(); await drain();
    assert.deepEqual(h.bytes, []);
    assert.deepEqual(h.pending.map(p => p.index), [5, 6]);
});

test("reader increases lookahead with device-scaled pixel and concurrency budgets", () => {
    const policy = source.slice(source.indexOf("const MAX_PREDECODED_IMAGES"), source.indexOf("const preloadedSizes"));
    for (const memory of [undefined, 4, 8]) {
        let loader, queue;
        vm.runInNewContext(policy, {
            navigator: { deviceMemory: memory },
            createReaderImageLoader: options => { loader = options; return {}; },
            createReaderPreloadQueue: options => { queue = options; return {}; },
        });
        assert.equal(loader.maxDecoded, memory >= 8 ? 12 : 8);
        assert.equal(loader.maxDecodedBytes, (memory >= 8 ? 1024 : 256) * 1024 * 1024);
        assert.equal(queue.concurrency, memory >= 8 ? 4 : 2);
        assert.equal(queue.pixelLimit, (memory >= 8 ? 128 : 32) * 1024 * 1024);
    }
});
