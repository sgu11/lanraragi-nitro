import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { before, after, test } from "node:test";
import { build } from "esbuild";
import { chromium } from "playwright-core";

const chrome = [process.env.CHROME_PATH, "/opt/google/chrome/chrome", "/usr/bin/google-chrome", "/usr/bin/chromium"]
    .find(path => path && existsSync(path));
const options = { skip: !chrome && "Chromium is required for reader DOM lifetime checks" };
let browser;
let script;
before(async () => {
    if (!chrome) return;
    browser = await chromium.launch({ executablePath: chrome, headless: true, args: ["--no-sandbox"] });
    const output = await build({
        stdin: { contents: 'export * from "./public/js/mod/reader-display.js"; export * from "./public/js/mod/reader-stamps.js";',
            resolveDir: fileURLToPath(new URL("../../", import.meta.url)) },
        bundle: true, format: "iife", globalName: "ReaderTest", write: false,
        alias: { "lrr-reader-display": fileURLToPath(new URL("../../public/js/mod/reader-display.js", import.meta.url)) },
    });
    script = output.outputFiles[0].text;
});
after(async () => { await browser?.close(); });

async function withPage(callback) {
    const page = await browser.newPage();
    try {
        await page.setContent('<div id="display" style="position:relative;display:flex"><img id="img" width="200" height="300" style="height:300px"><img id="img_doublepage" width="200" height="300" style="height:300px"></div>');
        await page.addScriptTag({ content: script });
        return await callback(page);
    } finally { await page.close(); }
}

test("decoded DOM identities and styles survive direction swaps, sliding and single pages", options, async () => {
    const result = await withPage(page => page.evaluate(() => {
        const a = document.getElementById("img");
        const b = document.getElementById("img_doublepage");
        const c = new Image();
        const swap = (first, second) => ReaderTest.replaceReaderImages([
            { selector: "#img", image: first }, { selector: "#img_doublepage", image: second },
        ]);
        swap(b, a);
        const reversed = document.getElementById("img") === b && document.getElementById("img_doublepage") === a;
        swap(a, b);
        swap(b, c);
        const slid = document.getElementById("img") === b && document.getElementById("img_doublepage") === c;
        const styles = [b.style.height, c.style.height];
        swap(c, new Image());
        return { reversed, slid, styles, single: document.getElementById("img") === c,
            slots: document.querySelectorAll("#img, #img_doublepage").length };
    }));
    assert.deepEqual(result, { reversed: true, slid: true, styles: ["300px", "300px"], single: true, slots: 2 });
});

test("stamp responses are spread-owned and disabled views do not request or display stamps", options, async () => {
    const result = await withPage(page => page.evaluate(async () => {
        const state = { displayWindow: { start: 0, end: 0 }, visible: true };
        const pending = [];
        const layer = ReaderTest.createReaderStamps({
            getState: () => state, getArchiveForPage: page => ({ arcId: "arc", localPage: page }),
            request: url => new Promise(resolve => pending.push({ url, resolve })),
        });
        const first = layer.refresh();
        state.displayWindow = { start: 2, end: 2 };
        const second = layer.refresh();
        const response = id => ({ result: [{ id, content: id, position: "25,50" }] });
        pending[1].resolve(response("current")); await second;
        pending[0].resolve(response("old")); await first;
        const ids = [...document.querySelectorAll(".marker")].map(el => el.dataset.stampId);
        const late = layer.refresh();
        state.visible = false;
        layer.clear();
        pending[2].resolve(response("hidden")); await late;
        await layer.refresh();
        state.visible = true; state.infiniteScroll = true;
        await layer.refresh();
        return { ids, remaining: document.querySelectorAll(".marker").length, requests: pending.length };
    }));
    assert.deepEqual(result, { ids: ["current"], remaining: 0, requests: 3 });
});

test("RTL stamp capture and requests keep archive-local coordinates across Tankoubon boundaries", options, async () => {
    const result = await withPage(page => page.evaluate(async () => {
        const requests = [];
        const state = { displayWindow: { start: 2, end: 3 }, mangaMode: true, visible: true };
        const layer = ReaderTest.createReaderStamps({ getState: () => state,
            getArchiveForPage: page => page <= 3 ? { arcId: "first", localPage: page } : { arcId: "second", localPage: page - 3 },
            request: async (url, method) => { requests.push({ url, method }); return { result: [] }; },
        });
        await layer.refresh();
        const image = document.getElementById("img");
        const rect = image.getBoundingClientRect();
        const captured = layer.capture(image, { clientX: rect.left + rect.width / 4, clientY: rect.top + rect.height / 2 });
        const text = "stamp & +? 日本語";
        await layer.add(captured, text);
        const create = requests.find(entry => entry.method === "PUT");
        const params = new URL(create.url, "https://example.test");
        return { reads: requests.slice(0, 2).map(item => item.url), pathname: params.pathname,
            position: params.searchParams.get("position"), content: params.searchParams.get("content") };
    }));
    assert.deepEqual(result, { reads: ["/api/archives/second/stamps/1", "/api/archives/first/stamps/3"],
        pathname: "/api/archives/second/stamps/1", position: "25,50", content: "stamp & +? 日本語" });
});

test("stamp redraws retain no document listeners and failed or cancelled drags restore navigation", options, async () => {
    const result = await withPage(page => page.evaluate(async () => {
        const live = new Map(["pointermove", "pointerup", "pointercancel"].map(name => [name, new Set()]));
        const add = document.addEventListener.bind(document);
        const remove = document.removeEventListener.bind(document);
        document.addEventListener = (name, fn, ...rest) => { live.get(name)?.add(fn); return add(name, fn, ...rest); };
        document.removeEventListener = (name, fn, ...rest) => { live.get(name)?.delete(fn); return remove(name, fn, ...rest); };
        let navigation = true;
        let errors = 0;
        const layer = ReaderTest.createReaderStamps({
            getState: () => ({ displayWindow: { start: 0, end: 0 }, visible: true }),
            getArchiveForPage: page => ({ arcId: "arc", localPage: page }),
            request: async (_url, method) => { if (method === "PUT") throw new Error("Unavailable");
                return { result: [{ id: "one", content: "one", position: "10,10" }] }; },
            setNavigationEnabled: enabled => { navigation = enabled; }, onError: () => { errors++; },
        });
        const count = () => [...live.values()].reduce((n, entries) => n + entries.size, 0);
        await layer.refresh();
        for (let i = 0; i < 100; i++) layer.render();
        const idle = count();
        const event = type => new PointerEvent(type, { pointerId: 1, button: 0, clientX: 50, clientY: 50, bubbles: true });
        document.querySelector(".marker").dispatchEvent(event("pointerdown"));
        const active = { listeners: count(), navigation };
        document.dispatchEvent(event("pointerup"));
        await new Promise(resolve => setTimeout(resolve, 0));
        const failed = { listeners: count(), navigation, errors };
        document.querySelector(".marker").dispatchEvent(event("pointerdown"));
        layer.dispose();
        return { idle, active, failed, disposed: { listeners: count(), navigation, markers: document.querySelectorAll(".marker").length } };
    }));
    assert.deepEqual(result, { idle: 0, active: { listeners: 3, navigation: false },
        failed: { listeners: 0, navigation: true, errors: 1 }, disposed: { listeners: 0, navigation: true, markers: 0 } });
});
