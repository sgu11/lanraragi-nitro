import test from 'node:test';
import assert from 'node:assert/strict';
import { loadAdaptiveOffset } from '../../public/js/mod/reader-spread.js';

const ready = { archiveId: 'a', contentRevision: 'b'.repeat(64), status: 'ready', first_spread_start: 'UNKNOWN', segments: [] };
const wait = () => new Promise(resolve => setTimeout(resolve, 15));

test('transient failure and pending state retry; valid UNKNOWN is delivered once', async () => {
    let calls = 0;
    const results = [];
    const cancel = loadAdaptiveOffset({ archiveId: 'a', intervalMs: 0, request: async () => {
        calls++;
        if (calls === 1) throw new Error('503');
        return calls === 2 ? { status: 'pending' } : ready;
    }, commit: result => results.push(result) });
    await wait();
    cancel();
    assert.equal(calls, 3);
    assert.deepEqual(results, [ready]);
});

test('cancelled late response cannot overwrite a manual slide or another archive', async () => {
    let deliver;
    let signal;
    const results = [];
    const cancel = loadAdaptiveOffset({ archiveId: 'a', request: async s => { signal = s; return new Promise(resolve => { deliver = resolve; }); },
        commit: result => results.push(result) });
    cancel();
    deliver(ready);
    await wait();
    assert.equal(signal.aborted, true);
    assert.deepEqual(results, []);
});

test('wrong archive and malformed revisions never deliver and polling is bounded', async () => {
    let calls = 0;
    const results = [];
    const cancel = loadAdaptiveOffset({ archiveId: 'a', attempts: 3, intervalMs: 0,
        request: async () => { calls++; return { ...ready, ...(calls === 1 ? { archiveId: 'other' } : { contentRevision: 'old' }) }; },
        commit: result => results.push(result) });
    await wait();
    cancel();
    assert.equal(calls, 3);
    assert.deepEqual(results, []);
});

test('an unresponsive request is aborted by the total deadline', async () => {
    let signal;
    let deliver;
    const results = [];
    const cancel = loadAdaptiveOffset({ archiveId: 'a', timeoutMs: 1,
        request: async s => { signal = s; return new Promise(resolve => { deliver = resolve; }); },
        commit: result => results.push(result) });
    await wait();
    assert.equal(signal.aborted, true);
    deliver(ready);
    await wait();
    cancel();
    assert.deepEqual(results, []);
});
