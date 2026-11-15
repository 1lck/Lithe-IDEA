"use strict";
const path = require("path");

/**
 * Counts words.
 * @param {string} text
 * @returns {Map<string, number>}
 */
function count(text) {
  const words = new Map();
  for (const word of text.split(/\s+/g)) {
    if (!word) continue;
    words.set(word, (words.get(word) ?? 0) + 1);
  }
  return words;
}

class Counter extends EventTarget {
  #total = 0;
  static from(values) {
    const c = new Counter();
    values.forEach((v) => (c.#total += v));
    return c;
  }
  get total() {
    return this.#total;
  }
}

async function* lines(stream) {
  let rest = "";
  for await (const chunk of stream) {
    const parts = (rest + chunk).split("\n");
    rest = parts.pop();
    yield* parts;
  }
}

const { a = 1, ...others } = { a: 2, b: 'two', c: `three ${1 + 2}` };
const big = 123n, hex = 0x1f, exp = 1.5e-3;
module.exports = { count, Counter, lines, others, big, hex, exp, dir: path.dirname(__filename) };
