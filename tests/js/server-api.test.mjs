import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import vm from "node:vm";
import test from "node:test";
import { transform } from "esbuild";
import { createProgressWriteQueue } from "../../public/js/mod/reader-progress.js";

const source = await readFile(new URL("../../public/js/mod/server.js", import.meta.url), "utf8");
const { code } = await transform(source, { format: "cjs", target: "es2022" });

function setup(transport) {
    const errors = [];
    const toasts = [];
    const visibility = new Map();
    const module = { exports: {} };
    const common = {
        ApiURL: class { constructor(path) { this.path = path; } toString() { return `/library${this.path}`; } },
        toast: (value) => toasts.push(value),
        showErrorToast: (...args) => errors.push(args),
    };
    vm.runInNewContext(code, {
        module, exports: module.exports, URLSearchParams,
        require: (name) => ({ "lrr-common": common, i18n: {}, "lrr-reader-progress": { createProgressWriteQueue } })[name],
        fetch: transport,
        window: { location: { href: "https://example.test/library/config/plugins" } },
        FormData: class {},
        $: (selector) => ({
            0: {}, val: () => "value & more",
            show: () => visibility.set(selector, true),
            hide: () => visibility.set(selector, false),
        }),
        setTimeout,
    });
    return { api: module.exports, errors, toasts, visibility };
}

function response(data, status = 200) {
    return { status, ok: status >= 200 && status < 300, json: async () => data };
}

test("all API helpers reject HTTP and OpenAPI failures without success callbacks", async () => {
    for (const reply of [response({ message: "Unavailable" }, 503), response({ errors: [{ message: "Invalid" }] }, 400)]) {
        const { api, errors, toasts } = setup(async () => reply);
        let callbacks = 0;
        await api.callAPI("/api/example", "GET", "Saved", "Error", () => callbacks++);
        await api.callAPIBody("/api/example", "POST", "{}", "Saved", "Error", () => callbacks++);
        await assert.rejects(api.callAPISilent("/api/example", "GET"), /Unavailable|Invalid/);
        assert.equal(callbacks, 0);
        assert.equal(toasts.length, 0);
        assert.equal(errors.length, 2);
    }
});

test("empty successful response and omitted callback do not report failure", async () => {
    const { api, errors } = setup(async () => response(undefined, 204));
    await api.callAPI("/api/example", "DELETE", null, "Error");
    assert.equal(errors.length, 0);
});

test("concurrent GETs share transport and rejected requests can be retried", async () => {
    let requests = 0;
    let reject;
    const { api } = setup(() => {
        requests++;
        return new Promise((resolve, fail) => { reject = fail; });
    });
    const first = api.callAPI("/api/example", "GET", null, "Error");
    const second = api.callAPI("/api/example", "GET", null, "Error");
    assert.equal(requests, 1);
    reject(new Error("Disconnected"));
    await Promise.all([first, second]);
    const third = api.callAPI("/api/example", "GET", null, "Error");
    assert.equal(requests, 2);
    reject(new Error("Disconnected"));
    await third;
});

test("failed settings save prevents script execution and restores controls for retry", async () => {
    const calls = [];
    const { api, visibility } = setup(async (url) => {
        calls.push(String(url));
        return response({ success: 0, message: "Save failed" });
    });
    await api.triggerScript("plugin");
    assert.equal(calls.length, 1);
    assert.equal(visibility.get(".script-running"), false);
    assert.equal(visibility.get(".stdbtn"), true);
    await api.triggerScript("plugin");
    assert.equal(calls.length, 2, "another attempt can save settings");
});

test("queue failure restores controls and a retry saves before queueing", async () => {
    const calls = [];
    const { api, visibility } = setup(async (url) => {
        calls.push(String(url));
        return String(url).includes("/api/plugins/queue")
            ? response({ message: "Queue unavailable" }, 503)
            : response({ success: 1 });
    });
    await api.triggerScript("plugin");
    assert.equal(calls.length, 2);
    assert.match(calls[1], /\/library\/api\/plugins\/queue\?plugin=plugin&arg=value\+%26\+more/);
    assert.equal(visibility.get(".stdbtn"), true);
    await api.triggerScript("plugin");
    assert.equal(calls.length, 4);
});
