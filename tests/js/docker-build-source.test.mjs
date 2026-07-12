import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const source = (path) => readFile(new URL(`../../${path}`, import.meta.url), "utf8");

test("Docker runtime vendor trees come only from the clean build stage", async () => {
    const [dockerignore, dockerfile] = await Promise.all([
        source(".dockerignore"),
        source("tools/build/docker/Dockerfile"),
    ]);

    for (const path of ["public/js/vendor", "public/css/vendor", "public/css/webfonts"]) {
        assert.match(dockerignore, new RegExp(`^${path}$`, "m"));
    }
    assert.match(dockerfile, /RUN perl \.\/tools\/install\.pl install-front/);
    assert.match(dockerfile, /COPY --from=build[^\n]+public\/js\/vendor[^\n]+public\/js\/vendor/);
    assert.match(dockerfile, /COPY --from=build[^\n]+public\/css\/vendor[^\n]+public\/css\/vendor/);
    assert.match(dockerfile, /COPY --from=build[^\n]+public\/css\/webfonts[^\n]+public\/css\/webfonts/);
});
