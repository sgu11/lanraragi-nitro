import assert from "node:assert/strict";
import test from "node:test";
import {
    ARCHIVE_DATA_CACHE_MAX,
    getArchiveData,
    setArchiveData,
    clearArchiveDataCache,
    getArchiveDataCacheSize,
} from "../../public/js/mod/archive-data-cache.js";

test("shipped archive-data-cache is bounded LRU", () => {
    clearArchiveDataCache();
    assert.equal(ARCHIVE_DATA_CACHE_MAX, 500);
    assert.equal(getArchiveDataCacheSize(), 0);

    for (let i = 0; i < ARCHIVE_DATA_CACHE_MAX + 25; i++) {
        setArchiveData(`id${i}`, { i });
    }
    assert.equal(getArchiveDataCacheSize(), ARCHIVE_DATA_CACHE_MAX);
    assert.equal(getArchiveData("id0"), undefined, "oldest entries evicted");
    assert.deepEqual(
        getArchiveData(`id${ARCHIVE_DATA_CACHE_MAX + 24}`),
        { i: ARCHIVE_DATA_CACHE_MAX + 24 },
        "newest retained",
    );

    clearArchiveDataCache();
    for (let i = 0; i < ARCHIVE_DATA_CACHE_MAX; i++) {
        setArchiveData(`id${i}`, { i });
    }
    setArchiveData("keep-me", { k: 1 });
    getArchiveData("keep-me"); // LRU touch
    setArchiveData("overflow", { o: 1 });
    assert.deepEqual(getArchiveData("keep-me"), { k: 1 }, "LRU touch retains entry across one eviction");
    assert.equal(getArchiveDataCacheSize(), ARCHIVE_DATA_CACHE_MAX);

    clearArchiveDataCache();
    assert.equal(getArchiveDataCacheSize(), 0);
});
