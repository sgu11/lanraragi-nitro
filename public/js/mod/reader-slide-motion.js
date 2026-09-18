/*
 * Adapted from Suwayomi-WebUI 4bedf351, Copyright (C) Contributors to the Suwayomi project.
 * This Source Code Form is subject to the Mozilla Public License, v. 2.0.
 * https://mozilla.org/MPL/2.0/
 */
const bezier = (t, a, b) => 3 * (1 - t) ** 2 * t * a + 3 * (1 - t) * t * t * b + t ** 3;
const derivative = (t, a, b) => 3 * (1 - t) ** 2 * a + 6 * (1 - t) * t * (b - a) + 3 * t * t * (1 - b);
const slideTween = (from, to, velocity, duration) => {
    const distance = to - from;
    const y1 = Math.abs(distance) < 1e-3 ? 0 : velocity * duration * 0.2 / distance;
    return {
        duration,
        easing: `cubic-bezier(0.2, ${y1}, 0, 1)`,
        frames: [
            { position: from, offset: 0 },
            { position: to, offset: 1 }
        ],
        sample: (time) => {
            if (time <= 0) {
                return { position: from, velocity };
            }
            if (time >= duration) {
                return { position: to, velocity: 0 };
            }
            const progress = time / duration;
            let low = 0;
            let high = 1;
            for (let i = 0; i < 30; i++) {
                const mid = (low + high) / 2;
                if (bezier(mid, 0.2, 0) < progress) {
                    low = mid;
                } else {
                    high = mid;
                }
            }
            const t = (low + high) / 2;
            return {
                position: from + distance * bezier(t, y1, 1),
                velocity: distance / duration * derivative(t, y1, 1) / derivative(t, 0.2, 0)
            };
        }
    };
};
const slideSpring = (from, to, velocity, response) => {
    const offset = from - to;
    const omega = Math.max(8 / response, Math.abs(offset) > 1e-3 ? -velocity / offset : 0);
    const coefficient = velocity + omega * offset;
    const evaluate = (time) => {
        const decay = Math.exp(-omega * time);
        return {
            position: to + (offset + coefficient * time) * decay,
            velocity: (velocity - omega * coefficient * time) * decay
        };
    };
    let duration = 16;
    while (duration < 5e3) {
        const state = evaluate(duration);
        if (Math.abs(state.position - to) < 0.05 && Math.abs(state.velocity) < 5e-4) {
            break;
        }
        duration += 8;
    }
    const count = Math.max(2, Math.ceil(duration / 4));
    const frames = Array.from({ length: count + 1 }, (_, index) => ({
        position: index === count ? to : evaluate(duration * index / count).position,
        offset: index / count
    }));
    return {
        duration,
        easing: "linear",
        frames,
        sample: (time) => time >= duration ? { position: to, velocity: 0 } : evaluate(Math.max(0, time))
    };
};
export {
    slideSpring,
    slideTween
};
