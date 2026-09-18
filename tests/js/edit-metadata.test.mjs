import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import vm from "node:vm";
import test from "node:test";

const source = await readFile(new URL("../../public/js/edit.js", import.meta.url), "utf8");
function harness({ tank = false, rich = true, pending = "artist:new artist" } = {}) {
    const values = { "#archiveID": "archive", "#tagText": "language:korean", "#title": "Title", "#summary": "Summary" };
    const input = { value: pending };
    const requests = [];
    const context = vm.createContext({
        FormData, I18N: {}, jQuery() {},
        $: (selector) => ({
            0: selector === ".tagger-new input" ? input : undefined,
            val: () => values[selector],
            map: () => ({ get: () => ["archive"] }),
        }),
        Server: { callAPIBody: async (url, method, body) => { requests.push({ url, method, body }); } },
    });
    vm.runInContext(source.replace(/^import .*;$/gm, "") + "\nglobalThis.edit = Edit;", context);
    const edit = context.edit;
    edit.isTank = tank;
    edit.hideTags = edit.showTags = () => {};
    if (rich) edit.tagInput = { add_tag(tag) {
        const tags = values["#tagText"].split(",");
        if (tag && !tags.includes(tag)) values["#tagText"] += `,${tag}`;
    } };
    return { edit, input, values, requests };
}

for (const tank of [false, true]) {
    test(`save includes pending tags without Enter (${tank ? "tank" : "archive"})`, async () => {
        const h = harness({ tank, pending: " artist:new artist, group:new group " });
        await h.edit.saveMetadata();
        const body = h.requests[0].body;
        const tags = tank ? JSON.parse(body).metadata.tags : body.get("tags");
        assert.equal(tags, "language:korean,artist:new artist,group:new group");
        assert.equal(h.input.value, "");
        await h.edit.saveMetadata();
        assert.equal(h.values["#tagText"], tags, "repeated saves do not duplicate tags");
    });
}
test("plain mobile textarea remains the source of tags", async () => {
    const h = harness({ rich: false });
    await h.edit.saveMetadata();
    assert.equal(h.requests[0].body.get("tags"), "language:korean");
});
test("empty and duplicate pending tags preserve existing tags", async () => {
    for (const pending of ["  ", "language:korean"]) {
        const h = harness({ pending });
        await h.edit.saveMetadata();
        assert.equal(h.requests[0].body.get("tags"), "language:korean");
    }
});
test("plugin implicit save includes pending tags before running plugin", async () => {
    const h = harness();
    h.edit.getTags = () => assert.equal(h.requests[0].body.get("tags"), "language:korean,artist:new artist");
    h.edit.runPlugin();
    await new Promise((resolve) => setImmediate(resolve));
});

test("desktop initialization supplies an input to Tagger; mobile keeps textarea", async () => {
    for (const mobile of [false, true]) {
        let element = { tagName: "TEXTAREA", value: "artist:existing", attributes: [{ name: "id", value: "tagText" }], replaceWith(next) { element = next; } };
        let taggerCalls = 0;
        const document = { createElement(name) { return { tagName: name.toUpperCase(), setAttribute(key, value) { this[key] = value; } }; } };
        const context = vm.createContext({
            document, window: { localStorage: { getItem: () => null } },
            I18N: {}, jQuery() {}, LRR: { isMobile: () => mobile },
            $: () => ({ 0: element, on() {}, data: () => 0 }),
            Server: { callAPI: () => Promise.resolve() },
            tagger(input) {
                assert.equal(input.tagName, "INPUT", "Tagger requires the HTMLInputElement native setter");
                assert.equal(input.id, "tagText");
                assert.equal(input.value, "artist:existing");
                taggerCalls++;
                return {};
            },
        });
        vm.runInContext(source.replace(/^import .*;$/gm, "") + "\nglobalThis.edit = Edit;", context);
        context.edit.hideTags = context.edit.showTags = context.edit.updateOneShotArg = () => {};
        context.edit.initializeAll();
        await new Promise((resolve) => setImmediate(resolve));
        assert.equal(taggerCalls, mobile ? 0 : 1);
        assert.equal(element.tagName, mobile ? "TEXTAREA" : "INPUT");
    }
});
