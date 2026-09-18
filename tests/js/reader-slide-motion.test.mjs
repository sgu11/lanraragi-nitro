import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
const source = await readFile(new URL('../../public/js/mod/reader-slide-motion.js', import.meta.url), 'utf8');
const { slideTween, slideSpring } = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);
test('selected click duration and reversal retain measured position and velocity', () => {
    const first=slideTween(600,0,0,200);
    assert.deepEqual(first.sample(200),{position:0,velocity:0});
    const before=first.sample(55);
    for(const target of [-600,600]) {
        const next=slideTween(before.position,target,before.velocity,200);
        assert.deepEqual(next.sample(0),before);
        assert.ok(Math.abs((next.sample(0.001).position-before.position)/0.001-before.velocity)<0.01);
        assert.deepEqual(next.sample(200),{position:target,velocity:0});
    }
});
test('critical damping preserves release speed and never crosses target', () => {
    for(const response of [50,200,1000]) for(const velocity of [-4,-1,0,2]) {
        const motion=slideSpring(100,0,velocity,response);
        assert.deepEqual(motion.sample(0),{position:100,velocity});
        assert.ok(motion.frames.every(({position})=>Number.isFinite(position)&&position>=0));
        assert.deepEqual(motion.sample(motion.duration),{position:0,velocity:0});
    }
    assert.ok(slideSpring(100,0,0,100).duration<slideSpring(100,0,0,400).duration);
});
