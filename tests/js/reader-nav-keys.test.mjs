import assert from "node:assert/strict";
import test from "node:test";
import {
    READER_NAV_KEYDOWN_SUPPRESS,
    READER_NAV_CURSOR_HIDE_CODES,
    isReaderNavKeydownSuppress,
    shouldHideReaderCursorForKeyCode,
} from "../../public/js/mod/reader-nav-keys.js";

test("keydown suppress list covers space, page jump, and vertical slide keys", () => {
    for (const code of [32, 33, 34, 35, 36, 38, 40, 83, 87]) {
        assert.equal(isReaderNavKeydownSuppress(code), true, `code ${code} should suppress`);
    }
    assert.equal(isReaderNavKeydownSuppress(65), false, "A does not need keydown suppress");
    assert.deepEqual([...READER_NAV_KEYDOWN_SUPPRESS], [32, 33, 34, 35, 36, 38, 40, 83, 87]);
});

test("cursor-hide policy covers arrows and WASD page turns", () => {
    for (const code of [37, 38, 39, 40, 65, 68, 83, 87, 33, 34]) {
        assert.equal(shouldHideReaderCursorForKeyCode(code), true, `code ${code} should hide cursor`);
    }
    assert.equal(shouldHideReaderCursorForKeyCode(32), false, "space is not a cursor-hide nav key");
    assert.ok(READER_NAV_CURSOR_HIDE_CODES.includes(65));
});
