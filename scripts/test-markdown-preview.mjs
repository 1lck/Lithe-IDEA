import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const source = readFileSync(new URL('../macos/Sources/Lithe/Resources/MarkdownPreview/preview.js', import.meta.url), 'utf8');

// Exercise the production event handlers with a small DOM port. Rendering
// libraries are absent so these cases isolate document and outline state.
function preview() {
  const element = () => ({
    hidden: false, dataset: {}, children: [], listeners: {}, attributes: {},
    classList: { toggle() {} },
    addEventListener(name, callback) { this.listeners[name] = callback; },
    setAttribute(name, value) { this.attributes[name] = value; },
    removeAttribute(name) { delete this.attributes[name]; },
    append(child) { this.children.push(child); },
    replaceChildren() { this.children = []; },
    querySelectorAll() { return []; },
  });
  const nodes = Object.fromEntries(['content', 'toc', 'toc-list', 'toc-toggle', 'image-viewer', 'image-full', 'image-close'].map(id => [id, element()]));
  let headings = [];
  nodes.content.querySelectorAll = selector => selector === 'h1, h2, h3' ? headings : [];
  const document = {
    ...element(), body: element(), documentElement: { dataset: {}, scrollHeight: 800 },
    getElementById: id => nodes[id], createElement: element,
  };
  const window = { innerHeight: 800, scrollY: 0, addEventListener() {}, scrollTo() {} };
  vm.runInNewContext(source, { document, window, requestAnimationFrame: callback => callback() });
  return {
    nodes,
    escape: () => document.listeners.keydown({ key: 'Escape' }),
    toggle: () => nodes['toc-toggle'].listeners.click({ stopPropagation() {} }),
    async update(count, documentURL = 'file:///workspace/guide.md') {
      headings = Array.from({ length: count }, (_, i) => ({ id: '', tagName: 'H2', textContent: `Section ${i}`, scrollIntoView() {} }));
      await window.LithePreview.update({ documentURL, html: '' });
    },
  };
}

test('Escape without headings closes the image without changing the outline preference', { timeout: 1000 }, async () => {
  const page = preview();
  await page.update(1);
  assert.equal(page.nodes.toc.hidden, false);
  await page.update(0);
  page.nodes['image-viewer'].hidden = false;
  page.escape();
  assert.equal(page.nodes['image-viewer'].hidden, true);
  await page.update(1);
  assert.equal(page.nodes.toc.hidden, false);
});

test('explicit collapse survives refresh and missing headings, but resets for another document', { timeout: 1000 }, async () => {
  const page = preview();
  await page.update(1);
  page.escape();
  await page.update(2);
  assert.equal(page.nodes.toc.hidden, true);
  await page.update(0);
  page.escape();
  await page.update(1);
  assert.equal(page.nodes.toc.hidden, true);
  await page.update(1, 'file:///workspace/other.md');
  assert.equal(page.nodes.toc.hidden, false);
  page.toggle();
  assert.equal(page.nodes.toc.hidden, true);
});

test('heading navigation leaves the outline open', { timeout: 1000 }, async () => {
  const page = preview();
  await page.update(2);
  page.nodes['toc-list'].children[1].listeners.click({ preventDefault() {} });
  assert.equal(page.nodes.toc.hidden, false);
});
