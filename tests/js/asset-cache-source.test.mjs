import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const source = (path) => readFile(new URL(`../../${path}`, import.meta.url), "utf8");

test("versioned module paths also include deploy-specific asset cache busting", async () => {
    const app = await source("lib/LANraragi.pm");
    const index = await source("templates/index.html.tt2");
    const indexModule = await source("public/js/mod/index.js");
    const importmap = await source("templates/common/importmap.html.tt2");
    const reader = await source("templates/reader.html.tt2");
    const duplicatesCustom = await source("templates/duplicates_custom.html.tt2");
    const generic = await source("lib/LANraragi/Utils/Generic.pm");

    assert.match(app, /LRR_ASSET_VERSION/);
    assert.match(app, /asset_version/);
    assert.match(app, /use Digest::SHA qw\(sha1_hex\);/);
    assert.match(app, /sub get_source_asset_revision/);
    assert.match(app, /get_git_revision\(\) \/\/ get_source_asset_revision\(\)/);

    assert.match(index, /\/js\/\$version\/mod\/index\.js\?\$asset_version/);
    assert.match(index, /\/js\/\$version\/mod\/common\.js\?\$asset_version/);
    assert.match(importmap, /\/js\/i18n\.js\?\$asset_version/);
    assert.match(indexModule, /from "progress-migration"/);
    assert.match(importmap, /"progress-migration": "\[% c\.url_for\("\/js\/\$version\/mod\/progress-migration\.js\?\$asset_version"\) %\]"/);
    assert.match(importmap, /\/js\/\$version\/vendor\/preact\.module\.js\?\$asset_version/);
    assert.match(reader, /\/css\/lrr\.css\?\$asset_version/);
    assert.match(reader, /\/js\/reader\.js\?\$asset_version/);
    assert.match(duplicatesCustom, /duplicates_custom\.css"\) %]\?\[% asset_version %]-no-delete-confirm/);
    assert.match(duplicatesCustom, /duplicates_custom\.js"\) %]\?\[% asset_version %]-no-delete-confirm/);
    assert.match(generic, /eval \{ \$self->LRR_ASSET_VERSION \}/);
    assert.match(generic, /\/themes\/\$css_file\?\$asset_version/);
});

test("classic vendor scripts in index and reader are deferred and cache-busted", async () => {
    const index = await source("templates/index.html.tt2");
    const reader = await source("templates/reader.html.tt2");

    // Every classic vendor <script src> must be deferred (non-blocking) and
    // carry the deploy-specific cache-bust query, since after_static serves
    // /js/* with a 1-day Cache-Control and no ?$asset_version would let a
    // stale vendored copy survive a deploy for up to 24h.
    const extractVendorScriptAttrs = (html) => {
        const out = [];
        // Capture the attributes portion of each <script ...> tag whose src
        // points at /js/vendor/.
        const re = /<script\s+([^>]*?)>/g;
        let m;
        while ((m = re.exec(html)) !== null) {
            const attrs = m[1];
            if (attrs.includes("/js/vendor/")) {
                out.push(attrs);
            }
        }
        return out;
    };

    for (const attrs of extractVendorScriptAttrs(index)) {
        assert.match(attrs, /defer/, `index vendor script missing defer: ${attrs}`);
        assert.match(attrs, /\?\$asset_version/, `index vendor script missing ?$asset_version: ${attrs}`);
    }
    // Sanity: the index actually has the heavy vendor set we expect deferred.
    // The src URL is wrapped in [% c.url_for("...?$asset_version") %], so the
    // cache-bust query sits inside the template helper and defer follows the
    // closing %].
    assert.match(index, /swiper-bundle\.min\.js\?\$asset_version"\) %\]"\s+defer/);
    assert.match(index, /jquery\.min\.js\?\$asset_version"\) %\]"\s+defer/);

    for (const attrs of extractVendorScriptAttrs(reader)) {
        assert.match(attrs, /defer/, `reader vendor script missing defer: ${attrs}`);
        assert.match(attrs, /\?\$asset_version/, `reader vendor script missing ?$asset_version: ${attrs}`);
    }
    // raty is only loaded for logged-in readers (the rating widget is gated
    // behind IF userlogged); jquery + contextMenu always load.
    assert.match(reader, /jquery\.min\.js\?\$asset_version"\) %\]"\s+defer/);
    assert.match(reader, /\[% IF userlogged %\][\s\S]*?raty\.min\.js\?\$asset_version"\) %\]"\s+defer/);
});

test("reader dependencies resolve through asset-versioned import map entries", async () => {
    const importmap = await source("templates/common/importmap.html.tt2");
    const reader = await source("public/js/reader.js");
    const server = await source("public/js/mod/server.js");

    assert.match(importmap, /"lrr-common": "\[% c\.url_for\("\/js\/\$version\/mod\/common\.js\?\$asset_version"\) %\]"/);
    assert.match(importmap, /"lrr-server": "\[% c\.url_for\("\/js\/\$version\/mod\/server\.js\?\$asset_version"\) %\]"/);
    assert.match(importmap, /"lrr-perf": "\[% c\.url_for\("\/js\/\$version\/mod\/perf\.js\?\$asset_version"\) %\]"/);
    assert.match(importmap, /"lrr-reader-chrome": "\[% c\.url_for\("\/js\/\$version\/mod\/reader-chrome\.js\?\$asset_version"\) %\]"/);
    assert.match(importmap, /"lrr-reader-spread": "\[% c\.url_for\("\/js\/\$version\/mod\/reader-spread\.js\?\$asset_version"\) %\]"/);

    assert.match(reader, /from "lrr-server"/);
    assert.match(reader, /from "lrr-common"/);
    assert.match(reader, /from "lrr-perf"/);
    assert.match(reader, /from "lrr-reader-chrome"/);
    assert.match(reader, /from "lrr-reader-spread"/);
    assert.doesNotMatch(reader, /from "\.\/mod\/reader-spread\.js"/);

    assert.match(server, /from "lrr-common"/);
    assert.doesNotMatch(server, /from "\.\/common\.js"/);
});
