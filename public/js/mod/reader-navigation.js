/** Preserve library ordering and filters when crossing a DataTables page. */
export function buildReaderNeighborSearch(datatablesPage, storage) {
    const pageSize = parseInt(storage.getItem("datatablesPageSize") || "100", 10);
    const params = new URLSearchParams({
        start: String((datatablesPage - 1) * pageSize),
        sortby: storage.getItem("indexSort") || "title",
        order: storage.getItem("indexOrder") === "desc" ? "desc" : "asc",
    });
    const filter = storage.getItem("currentSearch");
    if (filter) params.set("filter", filter);
    const category = storage.getItem("selectedCategory");
    if (category === "NEW_ONLY") params.set("newonly", "true");
    else if (category === "UNTAGGED_ONLY") params.set("untaggedonly", "true");
    else if (category) params.set("category", category);
    if (storage.getItem("grouptanks") === "false") params.set("groupby_tanks", "false");
    if (storage.getItem("hidecompleted") === "true") params.set("hidecompleted", "true");
    return `/api/search/ids?${params}`;
}
