import assert from "node:assert/strict";
import test from "node:test";
import { createBatchSession } from "../../public/js/mod/batch-session.js";

function harness(archives = ["a", "b"], options = {}) {
    const sent = [], timers = new Map(), closed = [], results = [], errors = [];
    const socket = { send: (text) => sent.push(JSON.parse(text)), close: (code) => closed.push(code) };
    let timerId = 0;
    const session = createBatchSession({ socket, archives, command: { operation: "delete" }, cooldown: 10,
        onResult: (result) => results.push(result), onWait: () => {}, onError: (error) => errors.push(error), onClose: () => {},
        schedule: (fn) => { timerId += 1; timers.set(timerId, fn); return timerId; },
        unschedule: (id) => timers.delete(id), ...options });
    const respond = (id, success = 1) => socket.onmessage({ data: JSON.stringify({ id, success }) });
    return { socket, session, sent, timers, closed, results, errors, respond };
}

test("cancelled cooldown cannot send an old archive to a restarted session, even if queued", () => {
    const old = harness(); old.socket.onopen(); old.respond("a");
    const staleTimer = [...old.timers.values()][0];
    old.session.cancel();
    const next = harness(["c", "d"]); next.socket.onopen();
    staleTimer();
    assert.deepEqual(old.sent.map((row) => row.archive), ["a"]);
    assert.deepEqual(next.sent.map((row) => row.archive), ["c"]);
    assert.equal(old.timers.size, 0);
    old.respond("a");
    assert.equal(old.results.length, 1);
});

test("matching result schedules once, duplicate responses cannot advance the queue", () => {
    const h = harness(); h.socket.onopen(); h.respond("a"); h.respond("a");
    assert.equal(h.results.length, 1); assert.equal(h.timers.size, 1);
    [...h.timers.values()][0](); h.respond("b", 0);
    assert.deepEqual(h.sent.map((row) => row.archive), ["a", "b"]);
    assert.deepEqual(h.closed, [1000]); assert.equal(h.results.length, 2);
});

test("malformed or unrelated responses stop the batch without another mutation", () => {
    for (const data of ["{", JSON.stringify({ id: "other", success: 1 }), JSON.stringify({ id: "a" })]) {
        const h = harness(); h.socket.onopen(); h.socket.onmessage({ data });
        assert.equal(h.errors.length, 1); assert.equal(h.sent.length, 1); assert.equal(h.timers.size, 0);
        h.respond("a"); assert.equal(h.results.length, 0);
    }
});

test("dispose releases callbacks and an empty queue sends no archive", () => {
    const h = harness([]); h.socket.onopen(); assert.equal(h.sent.length, 0);
    h.session.dispose();
    assert.equal(h.socket.onmessage, null); assert.equal(h.socket.onclose, null);
});

test("transport errors and send exceptions stop queued work", () => {
    const h = harness(); h.socket.send = () => { throw new Error("closed"); };
    h.socket.onopen(); assert.equal(h.errors.length, 1); assert.equal(h.timers.size, 0);
});
