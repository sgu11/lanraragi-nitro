/**
 * Reader chrome predicates kept outside reader.js so fork-only layout policy
 * stays in a small, testable module.
 */

export function isReaderMinimalChrome(infiniteScroll, headerHidden) {
    return Boolean(infiniteScroll || headerHidden);
}

export function getFitHeightViewportPercent(infiniteScroll, headerHidden) {
    if (headerHidden && !infiniteScroll) {
        return 100;
    }
    return infiniteScroll ? 98 : 90;
}

export function shouldWheelNavigatePages({ infiniteScroll, fullscreen, headerHidden }) {
    return !infiniteScroll && (fullscreen || headerHidden);
}
