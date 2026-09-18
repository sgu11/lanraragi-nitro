import test from 'node:test';
import assert from 'node:assert/strict';
import { buildSpreadWindows, getPageNavigationDestination } from '../../public/js/mod/reader-spread.js';

const revision = 'a'.repeat(64);
const anchor = (extra = {}) => ({ archiveId: 'archive-a', contentRevision: revision, segmentStart: 2, segmentEnd: 12,
    firstPairStart: 3, boundary: 'until_next_wide', provenance: 'detector', ...extra });
const state = (extra = {}) => ({ archiveId: 'archive-a', contentRevision: revision, maxPage: 11,
    doublePageMode: true, firstSpreadStart: 2, widePages: new Set([0, 1]), segments: [anchor()], ...extra });
const pairs = (s) => buildSpreadWindows(s.maxPage, s).map(({ start, end }) => [start, end]);

test('H14-shaped local anchor leaves the first portrait alone after two landscape pages', () => {
    assert.deepEqual(pairs(state()), [[0,0],[1,1],[2,2],[3,4],[5,6],[7,8],[9,10],[11,11]]);
});

test('an inferred segment cannot cross the next wide discovered later', () => {
    assert.deepEqual(pairs(state({ widePages: new Set([0, 1, 6]) })), [[0,0],[1,1],[2,2],[3,4],[5,5],[6,6],[7,8],[9,10],[11,11]]);
});

test('another archive, stale revision, missing boundary and invalid first-pair indices are ignored', () => {
    const baseline = pairs(state({ segments: [] }));
    for (const extra of [{ archiveId: 'archive-b' }, { contentRevision: 'b'.repeat(64) },
        { boundary: 'unbounded' }, { firstPairStart: 4 }, { segmentEnd: 13 }, { provenance: 'model_guess' }]) {
        assert.deepEqual(pairs(state({ segments: [anchor(extra)] })), baseline);
    }
    assert.deepEqual(pairs(state({ contentRevision: 'b'.repeat(64) })), baseline);
});

test('human correction wins only in its own valid segment; conflicting equal-priority anchors abstain', () => {
    const normal = pairs(state({ segments: [] }));
    assert.deepEqual(pairs(state({ segments: [anchor(), anchor({ provenance: 'user_slide', firstPairStart: 2 })] })), normal);
    assert.deepEqual(pairs(state({ segments: [anchor({ firstPairStart: 2 }), anchor()] })), normal);
    assert.deepEqual(pairs(state({ segments: [anchor({ provenance: 'user_slide', firstPairStart: 2 }), anchor()] })), normal);
});

test('local navigation is reversible and every source page appears once', () => {
    const s = state();
    assert.equal(getPageNavigationDestination(1, { ...s, currentPage: 3 }), 5);
    assert.equal(getPageNavigationDestination(-1, { ...s, currentPage: 5 }), 3);
    const indices = buildSpreadWindows(11, s).flatMap(({ start, end }) => Array.from({ length: end - start + 1 }, (_, i) => start + i));
    assert.deepEqual(indices, Array.from({ length: 12 }, (_, i) => i));
});

test('single-page mode ignores segment anchors', () => {
    assert.deepEqual(pairs(state({ doublePageMode: false })), Array.from({ length: 12 }, (_, i) => [i, i]));
});
