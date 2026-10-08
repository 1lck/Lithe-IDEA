import { afterEach, expect, test } from "bun:test";
import { createWheelScrollAnimation, type ScrollAnimationScheduler } from "./wheel-scroll-animation";

class ManualFrames implements ScrollAnimationScheduler {
  time = 0;
  nextId = 0;
  callbacks = new Map<number, () => void>();
  now = () => this.time;
  request = (callback: () => void) => {
    this.callbacks.set(++this.nextId, callback);
    return this.nextId;
  };
  cancel = (id: number) => { this.callbacks.delete(id); };
  advance(time: number) {
    this.time = time;
    const callbacks = [...this.callbacks.values()];
    this.callbacks.clear();
    for (const callback of callbacks) callback();
  }
}

const cleanups: (() => void)[] = [];
afterEach(() => { for (const cleanup of cleanups.splice(0)) cleanup(); });

function viewport(position = 0) {
  const frames = new ManualFrames();
  const state = { position, maximum: 600 };
  const animation = createWheelScrollAnimation({
    read: () => state.position,
    write: (next) => { state.position = next; },
    maximum: () => state.maximum,
    scheduler: frames,
  });
  cleanups.push(animation.stop);
  return { state, frames, animation };
}

test("wheel moves through intermediate positions and finishes at the Windows IDEA duration", () => {
  const { state, frames, animation } = viewport();
  expect(animation.scroll(120)).toBe(true);
  expect(state.position).toBe(0);
  frames.advance(100);
  // The Windows curve crosses y≈0.689 when x=0.5; CSS ease-out differs.
  expect(state.position).toBe(83);
  frames.advance(199);
  expect(state.position).toBeLessThanOrEqual(120);
  frames.advance(200);
  expect(state.position).toBe(120);
  expect(frames.callbacks.size).toBe(0);
});

test("repeated downward wheel input accumulates the destination without jumping", () => {
  const { state, frames, animation } = viewport();
  animation.scroll(120);
  frames.advance(50);
  const previous = state.position;
  animation.scroll(120);
  expect(state.position).toBe(previous);
  expect(frames.callbacks.size).toBe(1);
  frames.advance(100);
  expect(state.position).toBeGreaterThan(previous);
  expect(state.position).toBeLessThan(240);
  frames.advance(300);
  expect(state.position).toBe(240);
  expect(frames.callbacks.size).toBe(0);
});

test("reversing direction replaces the pending destination from the visible position", () => {
  const { state, frames, animation } = viewport(300);
  animation.scroll(200);
  frames.advance(100);
  const previous = state.position;
  animation.scroll(-100);
  frames.advance(150);
  expect(state.position).toBeLessThan(previous);
  frames.advance(300);
  expect(state.position).toBe(previous - 100);
  expect(frames.callbacks.size).toBe(0);
});

test("boundary input stays owned until arrival, then can bubble to an outer scroller", () => {
  const { state, frames, animation } = viewport(500);
  animation.scroll(200);
  expect(animation.scroll(200)).toBe(true);
  expect(state.position).toBe(500);
  frames.advance(200);
  expect(state.position).toBe(600);
  expect(animation.scroll(200)).toBe(false);
  state.position = 0;
  expect(animation.scroll(-200)).toBe(false);
  expect(frames.callbacks.size).toBe(0);
});

test("external navigation cancels pending frames and owns the next wheel origin", () => {
  const { state, frames, animation } = viewport();
  animation.scroll(120);
  frames.advance(50);
  state.position = 400;
  frames.advance(100);
  expect(state.position).toBe(400);
  expect(frames.callbacks.size).toBe(0);
  animation.scroll(50);
  frames.advance(300);
  expect(state.position).toBe(450);
});

test("content shrink clamps an in-flight animation and releases its frame", () => {
  const { state, frames, animation } = viewport();
  animation.scroll(500);
  state.maximum = 10;
  frames.advance(100);
  expect(state.position).toBe(10);
  expect(frames.callbacks.size).toBe(0);
});

test("stop cancels the owned frame without applying the rest of the wheel delta", () => {
  const { state, frames, animation } = viewport();
  animation.scroll(120);
  frames.advance(50);
  const previous = state.position;
  animation.stop();
  frames.advance(200);
  expect(state.position).toBe(previous);
  expect(frames.callbacks.size).toBe(0);
});
