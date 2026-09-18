import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const source = (path) => readFile(new URL(`../../${path}`, import.meta.url), "utf8");

test("toast and batch output sanitize untrusted server text", async () => {
    const [common, batch] = await Promise.all([
        source("public/js/mod/common.js"),
        source("public/js/batch.js"),
    ]);

    assert.match(common, /import DOMPurify from "dompurify"/);
    assert.match(common, /DOMPurify\.sanitize\(/);
    assert.match(batch, /document\.createTextNode\(String\(message \?\? ""\)\)/);
    assert.doesNotMatch(batch, /\$\("#log-container"\)\.append/);
});

test("internal URLs honor base paths and user values use URLSearchParams", async () => {
    const [plugins, logs, category, edit, server] = await Promise.all([
        source("public/js/plugins.js"),
        source("public/js/logs.js"),
        source("public/js/category.js"),
        source("public/js/edit.js"),
        source("public/js/mod/server.js"),
    ]);

    assert.match(plugins, /new LRR\.ApiURL\("\/config\/plugins\/upload"\)/);
    assert.match(logs, /fetch\(new LRR\.ApiURL\(`/);
    for (const javascript of [logs, category, edit, server]) {
        assert.match(javascript, /new URLSearchParams\(/);
    }
});

test("category saves are ordered and plugin scripts wait for form persistence", async () => {
    const [category, server] = await Promise.all([
        source("public/js/category.js"),
        source("public/js/mod/server.js"),
    ]);

    assert.match(category, /Category\.saveQueue = Category\.saveQueue/);
    assert.match(category, /revision !== Category\.saveRevision/);
    assert.match(server, /\.then\(\(saved\) => saved && callAPI\(/);
    assert.doesNotMatch(server, /\.then\(callAPI\(/);
});

test("reader table-of-contents text is query encoded", async () => {
    const reader = await source("public/js/mod/reader_common.js");
    assert.match(reader, /new URLSearchParams\(\{ page: localPage, title: result\.value \}\)/);
    assert.doesNotMatch(reader, /[?&](?:content|title)=\$\{result\.value\}/);
});

test("backup errors and custom column names stay text-only", async () => {
    const [backup, index] = await Promise.all([
        source("public/js/backup.js"),
        source("public/js/mod/index.js"),
    ]);
    assert.match(backup, /\$\("#result"\)\.text\(data\.result\.error\)/);
    assert.doesNotMatch(backup, /\.html\(data\.result\.error\)/);
    assert.match(index, /const columnLabel = LRR\.encodeHTML\(/);
    assert.doesNotMatch(index, /\$\(`#header-\$\{column\}`\)\.html\(/);
    assert.doesNotMatch(index, /\$\(`#header-\$\{i\}`\)\.html\(/);
});

test("development container bootstraps bind-mounted frontend assets", async () => {
    const dockerfile = await source("tools/build/docker/Dockerfile-dev");
    assert.match(dockerfile, /CMD \["sh", "-lc", "npm ci && perl tools\/install\.pl install-front/);
});

test("release jobs do not execute mutable third-party master branches", async () => {
    const workflow = await source(".github/workflows/release-delivery.yml");
    assert.doesNotMatch(workflow, /uses:\s+[^\n]+@master/);
    assert.match(workflow, /gh release upload/);
    assert.match(workflow, /curl --fail-with-body/);
});

test("failed authentication logs never interpolate submitted passwords", async () => {
    const login = await source("lib/LANraragi/Controller/Login.pm");
    assert.doesNotMatch(login, /Failed login attempt with password/);
    assert.match(login, /Failed login attempt from/);
});

test("download secrets and unauthenticated job errors are redacted", async () => {
    const [minionTasks, minionController] = await Promise.all([
        source("lib/LANraragi/Utils/Minion.pm"),
        source("lib/LANraragi/Controller/Api/Minion.pm"),
    ]);
    assert.doesNotMatch(minionTasks, /Downloading url \$url|transformed by plugin to \$url/);
    assert.match(minionController, /\$err = "Job failed\." if length\(\$err\) && !is_logged_in_api\(\$self\)/);
});
