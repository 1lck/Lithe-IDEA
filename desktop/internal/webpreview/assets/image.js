// The image viewer of an image file or an SVG buffer, with the macOS viewer's rules: the image
// follows its fitted scale until the user zooms; the fitted scale fills the viewport less 24px on
// each side and never enlarges; zoom runs from the lesser of 25% and the fitted scale to 400%, by
// steps of 25% from the toolbar, around the viewport's center, or around the pointer for a pinch.
//
// Host to page: {type: 'setup', theme}, {type: 'theme', theme}, {type: 'show', src, svg, keep},
// {type: 'zoom', by} or {type: 'zoom', to}.
// Page to host: {type: 'ready'}, {type: 'scale', scale, fit, width, height}, {type: 'failed'}.
(() => {
  'use strict';

  const bridge = window.viva;
  const viewport = document.getElementById('viewport');
  const stage = document.getElementById('stage');

  const PADDING = 24;
  const MAX_SCALE = 4;
  // An SVG without a size of its own is shown at the size CSS gives a replaced element.
  const DEFAULT_SIZE = { width: 300, height: 150 };

  let image = null;
  // natural is the image's own size; scale is null while the image follows its fitted scale.
  let natural = null;
  let scale = null;
  let showToken = 0;
  let reported = '';
  let drag = null;
  let gestureScale = 1;

  function post(message) {
    if (bridge) bridge.postMessage(JSON.stringify(message));
  }

  function applyTheme(value) {
    if (!value) return;
    const root = document.documentElement;
    root.dataset.theme = value.theme === 'dark' ? 'dark' : 'light';
    for (const [name, color] of Object.entries(value.variables || {})) {
      if (name.startsWith('--lithe-')) root.style.setProperty(name, color);
    }
  }

  function fitScale() {
    if (!natural) return 1;
    const width = Math.max(1, viewport.clientWidth - PADDING * 2) / natural.width;
    const height = Math.max(1, viewport.clientHeight - PADDING * 2) / natural.height;
    return Math.max(0.01, Math.min(width, height, 1));
  }

  function current() {
    return scale === null ? fitScale() : scale;
  }

  function clamp(value) {
    return Math.min(MAX_SCALE, Math.max(Math.min(0.25, fitScale()), value));
  }

  function center() {
    const box = viewport.getBoundingClientRect();
    return { x: box.left + box.width / 2, y: box.top + box.height / 2 };
  }

  function layout() {
    if (!image || !natural) return;
    const shown = current();
    image.style.width = natural.width * shown + 'px';
    image.style.height = natural.height * shown + 'px';
    const pannable = viewport.scrollWidth > viewport.clientWidth || viewport.scrollHeight > viewport.clientHeight;
    viewport.classList.toggle('pannable', pannable);
  }

  function report() {
    if (!natural) return;
    const message = { type: 'scale', scale: current(), fit: fitScale(), width: Math.round(natural.width), height: Math.round(natural.height) };
    const key = JSON.stringify(message);
    if (key === reported) return;
    reported = key;
    post(message);
  }

  // zoom sets the scale, null for the fitted one, keeping the image's point under anchor in place.
  function zoom(next, anchor) {
    if (!image || !natural) return;
    const before = image.getBoundingClientRect();
    const fx = before.width > 0 ? (anchor.x - before.left) / before.width : 0.5;
    const fy = before.height > 0 ? (anchor.y - before.top) / before.height : 0.5;
    scale = next === null ? null : clamp(next);
    layout();
    const after = image.getBoundingClientRect();
    viewport.scrollLeft += after.left + fx * after.width - anchor.x;
    viewport.scrollTop += after.top + fy * after.height - anchor.y;
    report();
  }

  function lengthOf(value) {
    const match = /^\s*([0-9]*\.?[0-9]+)\s*(px)?\s*$/.exec(value || '');
    return match ? parseFloat(match[1]) : 0;
  }

  // svgSize reads the size an SVG document declares: its width and height in pixels, completed by
  // its viewBox's proportions.
  async function svgSize(src) {
    try {
      const response = await fetch(src, { cache: 'no-store' });
      if (!response.ok) return null;
      const root = new DOMParser().parseFromString(await response.text(), 'image/svg+xml').documentElement;
      if (!root || root.localName !== 'svg') return null;
      let width = lengthOf(root.getAttribute('width'));
      let height = lengthOf(root.getAttribute('height'));
      const box = (root.getAttribute('viewBox') || '').trim().split(/[\s,]+/).map(Number);
      const ratio = box.length === 4 && box[2] > 0 && box[3] > 0 ? box[2] / box[3] : 0;
      if (!width && !height && ratio) {
        width = box[2];
        height = box[3];
      } else if (!width && height && ratio) {
        width = height * ratio;
      } else if (width && !height && ratio) {
        height = width / ratio;
      }
      return width > 0 && height > 0 ? { width, height } : null;
    } catch (_) {
      return null;
    }
  }

  // show loads src; keep holds the scale and the scroll position, for an SVG edited live.
  async function show(src, svg, keep) {
    const token = ++showToken;
    const declared = svg ? await svgSize(src) : null;
    if (token !== showToken) return;
    const next = new Image();
    next.alt = '';
    next.draggable = false;
    next.decoding = 'async';
    next.src = src;
    try {
      await next.decode();
    } catch (_) {
      if (token === showToken) post({ type: 'failed' });
      return;
    }
    if (token !== showToken) return;
    const left = viewport.scrollLeft;
    const top = viewport.scrollTop;
    natural = declared || (next.naturalWidth > 0 && next.naturalHeight > 0
      ? { width: next.naturalWidth, height: next.naturalHeight }
      : DEFAULT_SIZE);
    if (!keep) scale = null;
    else if (scale !== null) scale = clamp(scale);
    image = next;
    stage.replaceChildren(next);
    layout();
    viewport.scrollLeft = keep ? left : 0;
    viewport.scrollTop = keep ? top : 0;
    reported = '';
    report();
  }

  viewport.addEventListener('pointerdown', event => {
    if (event.button !== 0 || !viewport.classList.contains('pannable')) return;
    drag = { id: event.pointerId, x: event.clientX, y: event.clientY, left: viewport.scrollLeft, top: viewport.scrollTop };
    viewport.setPointerCapture(event.pointerId);
    viewport.classList.add('panning');
    event.preventDefault();
  });
  viewport.addEventListener('pointermove', event => {
    if (!drag || event.pointerId !== drag.id) return;
    viewport.scrollLeft = drag.left - (event.clientX - drag.x);
    viewport.scrollTop = drag.top - (event.clientY - drag.y);
  });
  const endDrag = event => {
    if (!drag || event.pointerId !== drag.id) return;
    drag = null;
    viewport.classList.remove('panning');
  };
  viewport.addEventListener('pointerup', endDrag);
  viewport.addEventListener('pointercancel', endDrag);

  // A pinch arrives as a wheel event with the control key (Chromium) or as gesture events (WebKit).
  viewport.addEventListener('wheel', event => {
    if (!event.ctrlKey || !natural) return;
    event.preventDefault();
    zoom(current() * Math.exp(-event.deltaY * 0.01), { x: event.clientX, y: event.clientY });
  }, { passive: false });
  document.addEventListener('gesturestart', event => {
    event.preventDefault();
    gestureScale = current();
  });
  document.addEventListener('gesturechange', event => {
    event.preventDefault();
    zoom(gestureScale * event.scale, { x: event.clientX, y: event.clientY });
  });
  document.addEventListener('gestureend', event => event.preventDefault());

  new ResizeObserver(() => {
    if (scale !== null) scale = clamp(scale);
    layout();
    report();
  }).observe(viewport);

  if (bridge) {
    bridge.onmessage = event => {
      let message;
      try {
        message = JSON.parse(event.data);
      } catch (_) {
        return;
      }
      switch (message?.type) {
        case 'setup':
        case 'theme':
          applyTheme(message.theme);
          break;
        case 'show':
          show(String(message.src || ''), Boolean(message.svg), Boolean(message.keep));
          break;
        case 'zoom':
          if (typeof message.to === 'number') zoom(message.to, center());
          else if (typeof message.by === 'number') zoom(current() + message.by, center());
          else zoom(null, center());
          break;
      }
    };
  }
  post({ type: 'ready' });
})();
