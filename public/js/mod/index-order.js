export const DEFAULT_INDEX_SORT_COLUMN = 1;
export const DEFAULT_INDEX_SORT_DIRECTION = "desc";

const LEGACY_INDEX_SORT_DIRECTION = "asc";

function hasStoredValue(value) {
    return value !== undefined && value !== null && value !== "";
}

function isStoredLegacyDefault(storage) {
    return storage.indexSort === "0" && storage.indexOrder === "asc";
}

function resolveSortColumn(sortValue, columns) {
    if (!hasStoredValue(sortValue)) {
        return null;
    }

    if (/^\d+$/.test(String(sortValue))) {
        return parseInt(sortValue, 10);
    }

    if (columns) {
        const sortColumn = Array.from(columns).findIndex((col) => col.sName === sortValue || col.name === sortValue);
        if (sortColumn !== -1) {
            return sortColumn;
        }
    }

    return 0;
}

export function getInitialIndexOrder(params, storage, currentCustomColumnCount, columns = null) {
    const shouldUseStoredOrder = !isStoredLegacyDefault(storage);
    const order = [[DEFAULT_INDEX_SORT_COLUMN, DEFAULT_INDEX_SORT_DIRECTION]];

    if (params.has("sort")) {
        order[0][0] = resolveSortColumn(params.get("sort"), columns);
        order[0][1] = LEGACY_INDEX_SORT_DIRECTION;
    } else if (hasStoredValue(storage.indexSort) && shouldUseStoredOrder) {
        order[0][0] = resolveSortColumn(storage.indexSort, columns);
        order[0][1] = LEGACY_INDEX_SORT_DIRECTION;
    }

    if (!Number.isInteger(order[0][0]) || order[0][0] > currentCustomColumnCount) {
        storage.indexSort = 0;
        order[0][0] = parseInt(storage.indexSort, 10);
    }

    if (params.has("sortdir")) {
        order[0][1] = params.get("sortdir");
    } else if (hasStoredValue(storage.indexOrder) && shouldUseStoredOrder) {
        order[0][1] = storage.indexOrder;
    }

    return order;
}
