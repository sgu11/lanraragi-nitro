/**
 * Fork-owned reader navigation key policy.
 *
 * Single source for which key codes suppress browser defaults on keydown and
 * which should hide the idle cursor. Adding a page-nav key should only require
 * editing this module.
 */

/** Key codes that need preventDefault on keydown (space / page jump / vertical slide). */
export const READER_NAV_KEYDOWN_SUPPRESS = Object.freeze([
    32, // space
    33, // page up
    34, // page down
    35, // end
    36, // home
    38, // up
    40, // down
    83, // s
    87, // w
]);

/** Key codes that hide the reader cursor immediately on navigation input. */
export const READER_NAV_CURSOR_HIDE_CODES = Object.freeze([
    33, 34, 35, 36, // page jump
    37, 38, 39, 40, // arrows
    65, 68, 83, 87, // a/d/s/w
]);

export function isReaderNavKeydownSuppress(which) {
    return READER_NAV_KEYDOWN_SUPPRESS.includes(which);
}

export function shouldHideReaderCursorForKeyCode(which) {
    return READER_NAV_CURSOR_HIDE_CODES.includes(which);
}
