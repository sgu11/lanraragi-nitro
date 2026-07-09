/**
 * Bounded LRU cache for archive/tankoubon thumbnail data seen on the index.
 * Kept pure (no DOM) so Node unit tests can import the shipped implementation.
 */

export const ARCHIVE_DATA_CACHE_MAX = 500;

const archiveDataCache = new Map();

export function getArchiveData(id) {
    if (!archiveDataCache.has(id)) {
        return undefined;
    }
    // Touch for LRU: re-insert moves key to the newest position.
    const data = archiveDataCache.get(id);
    archiveDataCache.delete(id);
    archiveDataCache.set(id, data);
    return data;
}

export function setArchiveData(id, data) {
    if (archiveDataCache.has(id)) {
        archiveDataCache.delete(id);
    }
    archiveDataCache.set(id, data);
    while (archiveDataCache.size > ARCHIVE_DATA_CACHE_MAX) {
        const oldest = archiveDataCache.keys().next().value;
        archiveDataCache.delete(oldest);
    }
}

export function clearArchiveDataCache() {
    archiveDataCache.clear();
}

export function getArchiveDataCacheSize() {
    return archiveDataCache.size;
}
