import assert from "node:assert/strict";
import test from "node:test";
import { buildReaderNeighborSearch } from "../../public/js/mod/reader-navigation.js";
import { getReaderPageSlots } from "../../public/js/mod/reader-display.js";

test("neighbor pages preserve title and namespace ordering in both directions", () => {
    for (const indexSort of ["title", "artist"]) {
        for (const indexOrder of ["asc", "desc"]) {
            const state = { indexSort, indexOrder, datatablesPageSize: "25" };
            const url = new URL(buildReaderNeighborSearch(3, { getItem: key => state[key] }), "https://example.test");
            assert.equal(url.searchParams.get("sortby"), indexSort);
            assert.equal(url.searchParams.get("order"), indexOrder);
            assert.equal(url.searchParams.get("start"), "50");
        }
    }
});

test("neighbor pages preserve encoded filters, categories and library flags", () => {
    for (const selectedCategory of ["NEW_ONLY", "UNTAGGED_ONLY", "SET_123 & test"]) {
        const state = { selectedCategory, currentSearch: "title:冒険 & more+?", grouptanks: "false", hidecompleted: "true" };
        const url = new URL(buildReaderNeighborSearch(1, { getItem: key => state[key] }), "https://example.test");
        assert.equal(url.searchParams.get("filter"), state.currentSearch);
        assert.equal(url.searchParams.get("groupby_tanks"), "false");
        assert.equal(url.searchParams.get("hidecompleted"), "true");
        if (selectedCategory === "NEW_ONLY") assert.equal(url.searchParams.get("newonly"), "true");
        else if (selectedCategory === "UNTAGGED_ONLY") assert.equal(url.searchParams.get("untaggedonly"), "true");
        else assert.equal(url.searchParams.get("category"), selectedCategory);
    }
});

test("page ownership follows the displayed slot for either reading direction", () => {
    assert.deepEqual(getReaderPageSlots({ start: 2, end: 3 }, false), [
        { selector: "#img", page: 2 }, { selector: "#img_doublepage", page: 3 },
    ]);
    assert.deepEqual(getReaderPageSlots({ start: 2, end: 3 }, true), [
        { selector: "#img", page: 3 }, { selector: "#img_doublepage", page: 2 },
    ]);
    for (const manga of [false, true]) {
        assert.deepEqual(getReaderPageSlots({ start: 5, end: 5 }, manga), [{ selector: "#img", page: 5 }]);
    }
});
