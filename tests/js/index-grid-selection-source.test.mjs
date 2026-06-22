import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const source = (path) => readFile(new URL(`../../${path}`, import.meta.url), "utf8");

test("fork grid selection is isolated behind a context-menu seam", async () => {
    const contextMenu = await source("public/js/mod/index_contextmenu.js");
    const gridSelection = await source("public/js/mod/index_grid_selection.js");

    assert.match(contextMenu, /import \* as GridSelection from "\.\/index_grid_selection\.js";/);
    assert.match(contextMenu, /GridSelection\.initialize\(catList\)/);
    assert.match(contextMenu, /GridSelection\.buildContextMenu\(id, catList\)/);
    assert.match(contextMenu, /GridSelection\.remove\(id\)/);

    assert.match(gridSelection, /document\.addEventListener\("contextmenu", handleContextMenuCapture, true\)/);
    assert.match(gridSelection, /localStorage\.setItem\("msmSelection", JSON\.stringify\(ids\)\)/);
    assert.match(gridSelection, /id\.startsWith\("TANK_"\)/);
    assert.match(gridSelection, /#msm-toggle,\s*#msm-carousel-controls,\s*#carousel-mode-menu/);
});

test("upstream MSM implementation remains present but is no longer the fork user path", async () => {
    const index = await source("public/js/mod/index.js");
    const common = await source("public/js/mod/common.js");
    const template = await source("templates/index.html.tt2");

    assert.match(index, /export let isMultiSelectMode = false;/);
    assert.match(index, /export function toggleMultiSelectMode\(\)/);
    assert.match(index, /function mergeSelectionIntoTankoubon\(\)/);
    assert.match(template, /id='msm-toggle'/);
    assert.doesNotMatch(common, /card-select/);
});
