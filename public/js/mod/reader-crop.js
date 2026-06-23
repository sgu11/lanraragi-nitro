/**
 * Fork-owned reader crop policy.
 *
 * Keep blank-border crop URL/state rules outside reader.js so upstream reader
 * changes only need a small integration point to preserve this feature.
 */

export const BORDER_CROP_CACHE_VERSION = "6";

export function readBorderCropPreference(storage = localStorage) {
    return storage.cropBorders === "true";
}

export function setBorderCropPreference(enabled, storage = localStorage) {
    const next = Boolean(enabled);
    storage.cropBorders = next ? "true" : "false";
    return next;
}

export function toggleBorderCropPreference(current, storage = localStorage) {
    return setBorderCropPreference(!current, storage);
}

export function applyBorderCropToggleState(enabled) {
    $("#toggle-border-crop input").removeClass("toggled");
    $(enabled ? "#border-crop-on" : "#border-crop-off").addClass("toggled");
    $("[id='toggle-border-crop-button']")
        .removeClass("fa-crop fa-crop-alt")
        .addClass(enabled ? "fa-crop" : "fa-crop-alt");
}

export function shouldRequestBorderCrop({ enabled, index, dimensions, isWidePage }) {
    if (!enabled) { return false; }
    if (index === 0) { return false; }
    if (isWidePage(dimensions)) { return false; }
    return true;
}

export function getReaderImageSource({ rawSrc, index, enabled, dimensions, isWidePage, baseHref = window.location.href }) {
    if (!rawSrc || !shouldRequestBorderCrop({ enabled, index, dimensions, isWidePage })) {
        return rawSrc;
    }

    const url = new URL(rawSrc, baseHref);
    url.searchParams.set("crop", "border");
    url.searchParams.set("cropv", BORDER_CROP_CACHE_VERSION);
    return `${url.pathname}${url.search}${url.hash}`;
}
