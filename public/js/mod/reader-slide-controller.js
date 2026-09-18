/*
 * Adapted from Suwayomi-WebUI 4bedf351, Copyright (C) Contributors to the Suwayomi project.
 * This Source Code Form is subject to the Mozilla Public License, v. 2.0.
 * https://mozilla.org/MPL/2.0/
 */
import {
    slideSpring,
    slideTween
} from "lrr-reader-slide-motion";
const frame = (rect) => ({
    display: "block",
    position: "fixed",
    pointerEvents: "none",
    left: `${rect.left}px`,
    top: `${rect.top}px`,
    width: `${rect.width}px`,
    height: `${rect.height}px`,
    minWidth: `${rect.width}px`,
    maxWidth: `${rect.width}px`,
    minHeight: `${rect.height}px`,
    maxHeight: `${rect.height}px`,
    margin: "0px"
});
const slideDistance = (old, next, direction) => Math.max(
    1,
    direction > 0 ? Math.max(...old.map(({ rect }) => rect.right)) - Math.min(...next.map(({ rect }) => rect.left)) : Math.max(...next.map(({ rect }) => rect.right)) - Math.min(...old.map(({ rect }) => rect.left))
);
class ReaderSlideController {
    tracks = /* @__PURE__ */ new Map();
    current = [];
    dragOrigins = /* @__PURE__ */ new Map();
    duration = 200;
    retire = () => {};
    sample(track) {
        return track.held ?? track.motion?.sample(Number(track.animation?.currentTime ?? 0)) ?? { position: track.target, velocity: 0 };
    }
    get images() {
        return this.current;
    }
    get busy() {
        return [...this.tracks.values()].some(
            ({ animation }) => animation?.playState === "running" || animation?.playState === "paused"
        );
    }
    refresh(images) {
        if (this.busy) {
            return;
        }
        this.clear();
        this.current = images;
        for (const entry of images) {
            this.tracks.set(entry.image, { ...entry, target: entry.rect.left });
        }
    }
    clear() {
        for (const track of this.tracks.values()) {
            track.animation?.cancel();
            this.retire(track.image);
        }
        this.tracks.clear();
        this.current = [];
        this.dragOrigins.clear();
    }
    animate(image, start, spring) {
        const track = this.tracks.get(image);
        track.animation?.cancel();
        track.held = void 0;
        const motion = (spring ? slideSpring : slideTween)(start.position, track.target, start.velocity, this.duration);
        const base = this.current.some((entry) => entry.image === track.image) ? {} : frame(track.rect);
        const animation = track.image.animate(
            motion.frames.map(({ position, offset }) => ({
                ...base,
                offset,
                transform: `translateX(${position - track.rect.left}px)`
            })),
            { duration: motion.duration, easing: motion.easing }
        );
        animation.id = this.current.some((entry) => entry.image === track.image) ? "reader-page-slide" : "reader-page-slide-outgoing";
        track.motion = motion;
        track.animation = animation;
        animation.onfinish = () => {
            if (track.animation === animation && !this.current.some((entry) => entry.image === track.image)) {
                this.tracks.delete(track.image);
                this.retire(track.image);
            }
        };
    }
    navigate(read, direction, spring = false) {
        const samples = new Map([...this.tracks].map(([image, track]) => [image, this.sample(track)]));
        for (const track of this.tracks.values()) {
            track.animation?.cancel();
        }
        const next = read();
        if (!this.current.length || !next.length || this.current.some(({ image }) => !image.isConnected)) {
            this.clear();
            this.refresh(next);
            return;
        }
        const distance = slideDistance(this.current, next, direction);
        const delta = -direction * distance;
        const [anchor] = this.current;
        const anchorState = samples.get(anchor.image) ?? { position: anchor.rect.left, velocity: 0 };
        const displacement = anchorState.position - anchor.rect.left;
        this.current = next;
        for (const [image, track] of this.tracks) {
            if (!image.isConnected) {
                this.tracks.delete(image);
                continue;
            }
            const destination = next.find((entry) => entry.image === image);
            const position = samples.get(image)?.position ?? track.target;
            // Repeated input must not retain an unlimited trail of invisible images.
            if (!destination && ((delta < 0 && position + track.rect.width < 0)
                || (delta > 0 && position > globalThis.innerWidth))) {
                this.tracks.delete(image);
                this.retire(image);
                continue;
            }
            track.target = destination?.rect.left ?? track.target + delta;
            if (destination) {
                track.rect = destination.rect;
            }
        }
        for (const entry of next) {
            if (!this.tracks.has(entry.image)) {
                this.tracks.set(entry.image, { ...entry, target: entry.rect.left });
                samples.set(entry.image, {
                    position: entry.rect.left - delta + displacement,
                    velocity: anchorState.velocity
                });
            }
        }
        for (const [image, track] of this.tracks) {
            this.animate(track.image, samples.get(image) ?? { position: track.target, velocity: 0 }, spring);
        }
        this.dragOrigins.clear();
    }
    beginDrag(neighbors) {
        for (const [image, track] of this.tracks) {
            track.held = this.sample(track);
            track.animation?.cancel();
            this.dragOrigins.set(image, track.held.position);
        }
        const [anchor] = this.current;
        if (!anchor) {
            return;
        }
        const displacement = (this.tracks.get(anchor.image)?.held?.position ?? anchor.rect.left) - anchor.rect.left;
        for (const { images, direction } of neighbors) {
            if (!images.length) {
                continue;
            }
            const distance = direction * slideDistance(this.current, images, direction);
            for (const entry of images) {
                if (this.tracks.has(entry.image)) {
                    continue;
                }
                const target = entry.rect.left + distance;
                this.tracks.set(entry.image, {
                    ...entry,
                    target,
                    held: { position: target + displacement, velocity: 0 }
                });
                this.dragOrigins.set(entry.image, target + displacement);
            }
        }
        this.moveDrag(0, 0);
    }
    moveDrag(offset, velocity) {
        for (const [image, track] of this.tracks) {
            const position = (this.dragOrigins.get(image) ?? track.target) + offset;
            track.held = { position, velocity };
            const base = this.current.some((entry) => entry.image === image) ? {} : frame(track.rect);
            const keyframe = { ...base, transform: `translateX(${position - track.rect.left}px)` };
            if (track.animation?.id !== "reader-page-drag") {
                track.animation?.cancel();
                track.animation = image.animate([keyframe, keyframe], { duration: 1e3 });
                track.animation.id = "reader-page-drag";
                track.animation.pause();
                track.animation.currentTime = 0;
            } else {
                track.animation.effect.setKeyframes([keyframe, keyframe]);
            }
        }
    }
    release(velocity) {
        for (const track of this.tracks.values()) {
            const state = this.sample(track);
            this.animate(track.image, { ...state, velocity }, true);
        }
        this.dragOrigins.clear();
    }
}
export {
    ReaderSlideController,
    slideDistance
};
