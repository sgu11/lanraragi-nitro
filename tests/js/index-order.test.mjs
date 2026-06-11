import assert from "node:assert/strict";
import test from "node:test";

import { getInitialIndexOrder } from "../../public/js/mod/index-order.js";

test("empty index URL defaults to descending date column", () => {
    const order = getInitialIndexOrder(new URLSearchParams(""), {}, 2);

    assert.deepEqual(order, [[1, "desc"]]);
});

test("explicit sort without sortdir keeps legacy ascending direction", () => {
    const order = getInitialIndexOrder(new URLSearchParams("sort=0"), {}, 2);

    assert.deepEqual(order, [[0, "asc"]]);
});

test("previous stored title ascending default migrates to descending date column", () => {
    const order = getInitialIndexOrder(new URLSearchParams(""), { indexSort: "0", indexOrder: "asc" }, 2);

    assert.deepEqual(order, [[1, "desc"]]);
});

test("saved non-default index order still wins when URL has no sort", () => {
    const order = getInitialIndexOrder(new URLSearchParams(""), { indexSort: "2", indexOrder: "asc" }, 2);

    assert.deepEqual(order, [[2, "asc"]]);
});
