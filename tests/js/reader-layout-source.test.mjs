import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const source = (path) => readFile(new URL(`../../${path}`, import.meta.url), "utf8");

test("paginated reader can use minimal chrome without enabling infinite scroll", async () => {
    const js = await source("public/js/reader.js");
    const css = await source("public/css/reader-chrome.css");
    const baseCss = await source("public/css/lrr.css");
    const template = await source("templates/reader.html.tt2");

    assert.match(js, /from "\.\/mod\/reader-chrome\.js";/);
    assert.match(js, /function applyReaderChromeLayout\(\) \{/);
    assert.match(js, /toggleClass\("infinite-scroll", infiniteScroll\)/);
    assert.match(js, /toggleClass\("reader-minimal-chrome", isReaderMinimalChrome\(infiniteScroll, localStorage\.hideHeader === "true"\)\)/);

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
    assert.match(css, /body\.reader-minimal-chrome #i4 \.absolute-options \{[\s\S]*display: flex;[\s\S]*flex-direction: column;[\s\S]*gap: 12px;[\s\S]*\}/);
    assert.match(css, /body\.reader-minimal-chrome #i4 \.absolute-options a \{[\s\S]*padding-right: 0;[\s\S]*\}/);
    assert.match(css, /body\.reader-minimal-chrome:not\(\.infinite-scroll\)\s*\{\s*overflow: hidden;\s*\}/);
    assert.match(css, /body\.reader-minimal-chrome:not\(\.infinite-scroll\) #i3\s*\{[\s\S]*min-height: 100vh;[\s\S]*display: flex;[\s\S]*align-items: center;[\s\S]*justify-content: center;[\s\S]*\}/);
    assert.match(css, /body\.reader-minimal-chrome:not\(\.infinite-scroll\) #display\s*\{[\s\S]*height: 100vh;[\s\S]*align-items: center;[\s\S]*\}/);
    assert.match(css, /body\.reader-minimal-chrome:not\(\.infinite-scroll\) \.reader-image\s*\{[\s\S]*max-height: 100vh;[\s\S]*\}/);
    assert.doesNotMatch(baseCss, /reader-minimal-chrome/);
    assert.match(baseCss, /body\.infinite-scroll #toggle-manga-mode,/);
    assert.match(baseCss, /body\.infinite-scroll #toggle-header,/);
    assert.match(baseCss, /body\.infinite-scroll #display img\s*\{[\s\S]*margin: 0 auto;[\s\S]*\}/);
    assert.match(template, /\/css\/reader-chrome\.css\?\$asset_version/);
    assert.match(js, /getFitHeightViewportPercent\(infiniteScroll, localStorage\.hideHeader === "true"\)/);
});

test("reader chrome exposes border crop toggle instead of help button", async () => {
    const js = await source("public/js/reader.js");
    const template = await source("templates/reader.html.tt2");
    const leftOptionsStart = template.indexOf("<div class=\"absolute-options absolute-left\">");
    const leftOptionsEnd = template.indexOf("<div class=\"absolute-options absolute-right\">", leftOptionsStart);
    const leftOptions = template.slice(leftOptionsStart, leftOptionsEnd);

    assert.notEqual(leftOptionsStart, -1);
    assert.notEqual(leftOptionsEnd, -1);
    assert.match(leftOptions, /id="toggle-settings-overlay"/);
    assert.match(leftOptions, /id="toggle-border-crop-button"/);
    assert.match(leftOptions, /fa-crop-alt/);
    assert.doesNotMatch(leftOptions, /id="toggle-help"/);
    assert.match(js, /\$\(document\)\.on\("click\.toggle-border-crop-button", "#toggle-border-crop-button", toggleBorderCrop\);/);

    const updateStart = js.indexOf("function updateBorderCropToggle()");
    const updateEnd = js.indexOf("function getReaderImageSource", updateStart);
    const updateBorderCropToggle = js.slice(updateStart, updateEnd);

    assert.notEqual(updateStart, -1);
    assert.notEqual(updateEnd, -1);
    assert.match(updateBorderCropToggle, /\$\(cropBorders \? "#border-crop-on" : "#border-crop-off"\)\.addClass\("toggled"\);/);
    assert.doesNotMatch(updateBorderCropToggle, /toggle-border-crop-button/);
});

test("reader border crop strings have English locale fallbacks", async () => {
    const locale = await source("locales/template/en.po");

    assert.match(locale, /msgid "Blank Border Cropping"\nmsgstr "Blank Border Cropping"/);
    assert.match(locale, /msgid "Requests reader page variants with blank scan borders removed\. Press K to toggle\."\nmsgstr "Requests reader page variants with blank scan borders removed\. Press K to toggle\."/);
    assert.match(locale, /msgid "K: toggle blank border cropping"\nmsgstr "K: toggle blank border cropping"/);
});

test("hidden-header paginated reader uses fullscreen wheel page navigation unless reader options are open", async () => {
    const js = await source("public/js/reader.js");
    const wheelStart = js.indexOf("function handleWheel(e)");
    const wheelEnd = js.indexOf("function checkFiletypeSupport", wheelStart);
    const wheel = js.slice(wheelStart, wheelEnd);

    assert.notEqual(wheelStart, -1);
    assert.notEqual(wheelEnd, -1);
    assert.match(wheel, /if \(\$\(("#settingsOverlay"|'#settingsOverlay')\)\.is\(":visible"\)\) return;/);
    assert.match(wheel, /if \(shouldWheelNavigatePages\(\{[\s\S]*infiniteScroll,[\s\S]*fullscreen: fscreen\.inFullscreen\(\),[\s\S]*headerHidden: localStorage\.hideHeader === "true",[\s\S]*\}\) && !wheelDebounce\) \{/);
    assert.match(wheel, /e\.preventDefault\(\);/);
    assert.match(wheel, /changePage\(direction, true\);/);
});

test("minimal double-spread reader uses vertical keys for single-page spread sliding", async () => {
    const js = await source("public/js/reader.js");
    const shortcutStart = js.indexOf("function handleShortcuts(e)");
    const shortcutEnd = js.indexOf("function handleWheel(e)", shortcutStart);
    const shortcut = js.slice(shortcutStart, shortcutEnd);
    const initStart = js.indexOf("export function initializeAll");
    const initEnd = js.indexOf("export function loadContentData", initStart);
    const init = js.slice(initStart, initEnd);

    assert.notEqual(shortcutStart, -1);
    assert.notEqual(shortcutEnd, -1);
    assert.notEqual(initStart, -1);
    assert.notEqual(initEnd, -1);
    assert.match(js, /getSinglePageSpreadWindow,/);
    assert.match(js, /getSpreadWindowWithPageShift,/);
    assert.match(js, /function shouldSlideSpreadWithVerticalKeys\(\) \{/);
    assert.match(js, /function slideSpreadBySinglePage\(step\) \{/);
    assert.match(js, /function shiftRequestedSpreadByPageCount\(step\) \{/);
    assert.match(js, /if \(shiftRequestedSpreadByPageCount\(step\)\) \{/);
    assert.match(shortcut, /case 38: \/\/ up arrow[\s\S]*slideSpreadBySinglePage\(-1\)/);
    assert.match(shortcut, /case 40: \/\/ down arrow[\s\S]*slideSpreadBySinglePage\(1\)/);
    assert.match(init, /if \(\[32, 38, 40\]\.includes\(e\.which\)\) handleShortcuts\(e\);/);
});

test("reader fit modes upscale cropped pages to the selected viewport or container", async () => {
    const js = await source("public/js/reader.js");
    const applyStart = js.indexOf("function applyContainerWidth()");
    const applyEnd = js.indexOf("function registerPreload()", applyStart);
    const applyContainerWidth = js.slice(applyStart, applyEnd);

    assert.notEqual(applyStart, -1);
    assert.notEqual(applyEnd, -1);
    assert.match(applyContainerWidth, /height: \$\{height\}vh; max-height: \$\{height\}vh; width: auto; object-fit: contain;/);
    assert.doesNotMatch(applyContainerWidth, /`max-height: \$\{height\}vh;`/);
    assert.match(applyContainerWidth, /"width: fit-content; width: -moz-fit-content; max-width: 100%"/);
    assert.match(applyContainerWidth, /`width: \$\{state\.containerWidth\}; max-width: 100%`/);
    assert.match(applyContainerWidth, /"width: 90%; max-width: 90%"[\s\S]*"width: 100%"/);
});
