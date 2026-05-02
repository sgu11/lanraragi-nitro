const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

function loadReader() {
    const source = fs.readFileSync(path.join(__dirname, "../../public/js/reader.js"), "utf8");
    const script = new vm.Script(`${source}\nReader;`);
    return script.runInNewContext({
        URLSearchParams,
        URL,
        document: {},
        window: {},
    });
}

test("first portrait dampener applies only to page after cover when enabled", () => {
    const Reader = loadReader();

    Reader.firstPortraitPageDamper = true;

    assert.equal(
        Reader.shouldUseFirstPortraitPageDamper(1, { width: 900, height: 1400 }),
        true,
    );
    assert.equal(
        Reader.shouldUseFirstPortraitPageDamper(0, { width: 900, height: 1400 }),
        false,
    );
    assert.equal(
        Reader.shouldUseFirstPortraitPageDamper(2, { width: 900, height: 1400 }),
        false,
    );
});

test("first portrait dampener ignores landscape, square, missing, and disabled pages", () => {
    const Reader = loadReader();

    Reader.firstPortraitPageDamper = true;

    assert.equal(
        Reader.shouldUseFirstPortraitPageDamper(1, { width: 1400, height: 900 }),
        false,
    );
    assert.equal(
        Reader.shouldUseFirstPortraitPageDamper(1, { width: 1000, height: 1000 }),
        false,
    );
    assert.equal(Reader.shouldUseFirstPortraitPageDamper(1, undefined), false);

    Reader.firstPortraitPageDamper = false;

    assert.equal(
        Reader.shouldUseFirstPortraitPageDamper(1, { width: 900, height: 1400 }),
        false,
    );
});

test("first portrait dampener makes the first double spread step back one page", () => {
    const Reader = loadReader();

    Reader.doublePageMode = true;
    Reader.doublePageOffset = false;
    Reader.firstPortraitPageDamper = true;
    Reader.showingSinglePage = false;
    Reader.currentPage = 2;
    Reader.preloadedDimensions[1] = { width: 900, height: 1400 };

    assert.equal(Reader.getPageNavigationOffset(-1), -1);

    Reader.firstPortraitPageDamper = false;

    assert.equal(Reader.getPageNavigationOffset(-1), -2);
});

test("first portrait dampener does not shorten manga-mode forward navigation", () => {
    const Reader = loadReader();

    Reader.doublePageMode = true;
    Reader.doublePageOffset = false;
    Reader.firstPortraitPageDamper = true;
    Reader.mangaMode = true;
    Reader.showingSinglePage = false;
    Reader.currentPage = 2;
    Reader.preloadedDimensions[1] = { width: 900, height: 1400 };

    assert.equal(Reader.getPageNavigationOffset(-1), -2);
    assert.equal(Reader.getPageNavigationOffset(1), 1);
});
