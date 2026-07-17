import assert from "node:assert/strict";
import { readFile, readdir } from "node:fs/promises";
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

test("theme inventory replaces the experimental theme with Catppuccin OLED", async () => {
    const themesDirectory = new URL("../../public/themes/", import.meta.url);
    const files = await readdir(themesDirectory);
    const mocha = await source("public/themes/catppuccin-mocha.css");
    const oled = await source("public/themes/catppuccin-oled.css");
    const generic = await source("lib/LANraragi/Utils/Generic.pm");

    assert.ok(!files.includes("test.css"));
    assert.ok(files.includes("catppuccin-oled.css"));
    assert.equal(
        oled,
        mocha
            .replace("LANraragi Theme: Catppuccin Mocha", "LANraragi Theme: Catppuccin OLED")
            .replace(
                "Soothing pastel theme based on the Catppuccin Mocha palette",
                "Catppuccin Mocha palette with true-black backgrounds for OLED displays",
            )
            .replaceAll("#1e1e2e", "#000000"),
    );
    assert.match(generic, /"catppuccin-mocha\.css"\s*\).*"Catppuccin Mocha",\s*"#1E1E2E"/);
    assert.match(generic, /"catppuccin-oled\.css"\s*\).*"Catppuccin OLED",\s*"#000000"/);
});
