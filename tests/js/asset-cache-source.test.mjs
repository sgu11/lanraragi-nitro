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
