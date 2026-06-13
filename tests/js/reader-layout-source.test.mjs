import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const source = (path) => readFile(new URL(`../../${path}`, import.meta.url), "utf8");

test("paginated reader can use minimal chrome without enabling infinite scroll", async () => {
    const js = await source("public/js/reader.js");
    const css = await source("public/css/lrr.css");

    assert.match(js, /function applyReaderChromeLayout\(\) \{/);
    assert.match(js, /toggleClass\("infinite-scroll", infiniteScroll\)/);
    assert.match(js, /toggleClass\("reader-minimal-chrome", infiniteScroll \|\| localStorage\.hideHeader === "true"\)/);

    const toggleHeaderStart = js.indexOf("function toggleHeader()");
    const toggleHeaderEnd = js.indexOf("function toggleProgressTracking()", toggleHeaderStart);
    const toggleHeader = js.slice(toggleHeaderStart, toggleHeaderEnd);

    assert.notEqual(toggleHeaderStart, -1);
    assert.notEqual(toggleHeaderEnd, -1);
    assert.match(toggleHeader, /localStorage\.hideHeader = localStorage\.hideHeader !== "true";/);
    assert.match(toggleHeader, /applyReaderChromeLayout\(\);/);
    assert.doesNotMatch(toggleHeader, /\$\(("#i2"|'#i2')\)\.toggle\(\)/);

    assert.match(css, /body\.reader-minimal-chrome \.sn,/);
    assert.match(css, /body\.reader-minimal-chrome \.file-info,/);
    assert.match(css, /body\.reader-minimal-chrome \.reading-direction/);
    assert.match(css, /body\.reader-minimal-chrome #i2\s*\{/);
    assert.match(css, /body\.reader-minimal-chrome #i5,\s*body\.reader-minimal-chrome #i7\s*\{\s*display: none;\s*\}/);
    assert.match(css, /body\.reader-minimal-chrome #i4 \.absolute-options \{/);
    assert.match(css, /body\.reader-minimal-chrome:not\(\.infinite-scroll\)\s*\{\s*overflow: hidden;\s*\}/);
    assert.match(css, /body\.reader-minimal-chrome:not\(\.infinite-scroll\) #i3\s*\{[\s\S]*min-height: 100vh;[\s\S]*display: flex;[\s\S]*align-items: center;[\s\S]*justify-content: center;[\s\S]*\}/);
    assert.match(css, /body\.reader-minimal-chrome:not\(\.infinite-scroll\) #display\s*\{[\s\S]*height: 100vh;[\s\S]*align-items: center;[\s\S]*\}/);
    assert.match(css, /body\.reader-minimal-chrome:not\(\.infinite-scroll\) \.reader-image\s*\{[\s\S]*max-height: 100vh;[\s\S]*\}/);
    assert.match(css, /body\.infinite-scroll #toggle-manga-mode,/);
    assert.match(css, /body\.infinite-scroll #toggle-header,/);
    assert.match(js, /localStorage\.hideHeader === "true" && !infiniteScroll\s*\? 100\s*:\s*infiniteScroll \? 98 : 90/);
});
