import assert from "node:assert/strict";
import test from "node:test";

import {
    BORDER_CROP_CACHE_VERSION,
    getReaderImageSource,
    readBorderCropPreference,
    setBorderCropPreference,
    shouldRequestBorderCrop,
    toggleBorderCropPreference,
} from "../../public/js/mod/reader-crop.js";

const isWidePage = (dimensions) => Boolean(dimensions?.width > dimensions?.height);

test("border crop preference reads and writes localStorage-compatible state", () => {
    const storage = {};

    assert.equal(readBorderCropPreference(storage), false);
    assert.equal(setBorderCropPreference(true, storage), true);
    assert.equal(storage.cropBorders, "true");
    assert.equal(readBorderCropPreference(storage), true);
    assert.equal(toggleBorderCropPreference(true, storage), false);
    assert.equal(storage.cropBorders, "false");
});

test("border crop only applies to non-cover non-wide reader pages", () => {
    assert.equal(shouldRequestBorderCrop({
        enabled: false,
        index: 1,
        dimensions: { width: 800, height: 1200 },
        isWidePage,
    }), false);
    assert.equal(shouldRequestBorderCrop({
        enabled: true,
        index: 0,
        dimensions: { width: 800, height: 1200 },
        isWidePage,
    }), false);
    assert.equal(shouldRequestBorderCrop({
        enabled: true,
        index: 2,
        dimensions: { width: 1600, height: 900 },
        isWidePage,
    }), false);
    assert.equal(shouldRequestBorderCrop({
        enabled: true,
        index: 2,
        dimensions: { width: 800, height: 1200 },
        isWidePage,
    }), true);
});

test("border crop URL policy appends cache-versioned crop parameters", () => {
    assert.match(BORDER_CROP_CACHE_VERSION, /^\d+$/);
    assert.equal(getReaderImageSource({
        rawSrc: "/api/archives/id/page?path=001.webp",
        index: 2,
        enabled: true,
        dimensions: { width: 800, height: 1200 },
        isWidePage,
        baseHref: "https://lanraragi.example/reader?id=id",
    }), `/api/archives/id/page?path=001.webp&crop=border&cropv=${BORDER_CROP_CACHE_VERSION}`);
    assert.equal(getReaderImageSource({
        rawSrc: "/api/archives/id/page?path=cover.webp",
        index: 0,
        enabled: true,
        dimensions: { width: 800, height: 1200 },
        isWidePage,
        baseHref: "https://lanraragi.example/reader?id=id",
    }), "/api/archives/id/page?path=cover.webp");
});
