import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const source = (path) => readFile(new URL(`../../${path}`, import.meta.url), "utf8");

test("Catppuccin index layout collapses hidden MOTD gap before quick filters", async () => {
    const indexTemplate = await source("templates/index.html.tt2");
    const theme = await source("public/themes/catppuccin-mocha.css");

    assert.match(indexTemplate, /<body class="index-page" data-user-logged="\[% userlogged %\]">/);
    assert.match(theme, /body\.index-page p#nb \{[\s\S]*margin-bottom: 0;[\s\S]*\}/);
    assert.match(theme, /body\.index-page div\.ido \{[\s\S]*padding-top: 0;[\s\S]*\}/);
    assert.match(theme, /body\.index-page #toppane > div\.idi:first-child \{[\s\S]*padding-top: 0;[\s\S]*\}/);
});
