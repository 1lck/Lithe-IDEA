// The rendered page of a Markdown file. The host sends Core's sanitized HTML; the page lays it out,
// renders math, code and diagrams, and keeps its scroll position in step with the editor by source
// line. It reaches nothing but its own origin: images are requested as res/<src>, and the host
// answers with what Core resolves the src to.
//
// Host to page: {type: 'setup', strings, theme}, {type: 'render', revision, html},
// {type: 'scroll', line}, {type: 'theme', theme}.
// Page to host: {type: 'ready'}, {type: 'rendered', revision, headings}, {type: 'scrolled', line},
// {type: 'link', href}.
(() => {
  'use strict';

  const bridge = window.viva;
  const content = document.getElementById('content');
  const viewer = document.getElementById('image-viewer');
  const fullImage = document.getElementById('image-full');
  const imageClose = document.getElementById('image-close');

  const XLINK = 'http://www.w3.org/1999/xlink';
  // Blocks whose source lines map the page to the editor. Inline elements share their block's lines.
  const BLOCKS = 'p, h1, h2, h3, h4, h5, h6, li, pre, blockquote, table, tr, hr, ul, ol, dl, dt, dd, details, figure, section, div';
  // Code blocks that are drawn rather than highlighted.
  const DRAWN = '.language-mermaid, .language-markmap, .language-math, [data-math-style]';
  const MERMAID_ENTRIES = 64;
  const HIGHLIGHT_ENTRIES = 256;
  // Auto-detecting the language of a long block on each keystroke costs more than it shows.
  const AUTO_DETECT_LIMIT = 20000;

  let strings = {};
  let theme = 'light';
  let mermaidTheme = '';
  let renderToken = 0;
  let shown = { revision: 0, html: '' };
  let markmaps = [];
  // points maps source lines to page offsets: sorted by line, offsets never decrease. null when
  // the layout changed since it was built.
  let points = null;
  let margin = 0;
  // topLine is the source line at the top of the page, kept through layout changes.
  let topLine = 1;
  // expectedY is the offset the page scrolled itself to; that scroll is not reported back.
  let expectedY = null;
  let reportFrame = 0;
  const scripts = new Map();
  const mermaidCache = new Map();
  const highlightCache = new Map();

  function post(message) {
    if (bridge) bridge.postMessage(JSON.stringify(message));
  }

  function remember(cache, limit, key, value) {
    cache.delete(key);
    cache.set(key, value);
    while (cache.size > limit) cache.delete(cache.keys().next().value);
  }

  function recall(cache, key) {
    if (!cache.has(key)) return undefined;
    const value = cache.get(key);
    cache.delete(key);
    cache.set(key, value);
    return value;
  }

  function loadScript(src) {
    let loading = scripts.get(src);
    if (!loading) {
      loading = new Promise((resolve, reject) => {
        const script = document.createElement('script');
        script.src = src;
        script.onload = () => resolve();
        script.onerror = () => reject(new Error(src));
        document.head.append(script);
      });
      scripts.set(src, loading);
    }
    return loading;
  }

  function applyTheme(value) {
    if (!value) return;
    theme = value.theme === 'dark' ? 'dark' : 'light';
    const root = document.documentElement;
    root.dataset.theme = theme;
    for (const [name, color] of Object.entries(value.variables || {})) {
      if (name.startsWith('--lithe-')) root.style.setProperty(name, color);
    }
  }

  function applyStrings(value) {
    strings = value || {};
    content.dataset.empty = strings.empty || '';
    viewer.setAttribute('aria-label', strings.imagePreview || '');
    imageClose.setAttribute('aria-label', strings.closeImage || '');
  }

  // Resources ---------------------------------------------------------------------------------

  function encodeReference(value) {
    let binary = '';
    for (const byte of new TextEncoder().encode(value)) binary += String.fromCharCode(byte);
    return btoa(binary).replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, '');
  }

  // resourceURL is where the page asks for an image: the host serves res/<src> with what Core
  // resolves the src to. A data URL of an image is kept; a fragment loads nothing.
  function resourceURL(raw) {
    const value = (raw || '').trim();
    if (!value || value.startsWith('#')) return '';
    if (/^data:image\//i.test(value)) return value;
    return 'res/' + encodeReference(value);
  }

  function rewrite(element, name, namespace) {
    const raw = namespace ? element.getAttributeNS(namespace, name) : element.getAttribute(name);
    if (raw === null) return;
    const url = resourceURL(raw);
    if (!url) {
      if (namespace) element.removeAttributeNS(namespace, name);
      else element.removeAttribute(name);
    } else if (namespace) {
      element.setAttributeNS(namespace, 'xlink:href', url);
    } else {
      element.setAttribute(name, url);
    }
  }

  function rewriteResources(root) {
    for (const image of root.querySelectorAll('img')) {
      image.removeAttribute('srcset');
      rewrite(image, 'src');
    }
    for (const image of root.querySelectorAll('image')) {
      rewrite(image, 'href');
      rewrite(image, 'href', XLINK);
    }
    for (const video of root.querySelectorAll('video[poster]')) rewrite(video, 'poster');
  }

  // reuseImages moves the loaded images of the page into the new one where the same src is shown
  // again, so typing does not load them again.
  function reuseImages(root) {
    const loaded = new Map();
    for (const image of content.querySelectorAll('img[src]')) {
      if (!image.complete || image.naturalWidth === 0) continue;
      const src = image.getAttribute('src');
      if (!loaded.has(src)) loaded.set(src, []);
      loaded.get(src).push(image);
    }
    if (loaded.size === 0) return;
    for (const image of root.querySelectorAll('img[src]')) {
      const old = loaded.get(image.getAttribute('src'))?.shift();
      if (!old) continue;
      for (const name of old.getAttributeNames()) {
        if (!image.hasAttribute(name)) old.removeAttribute(name);
      }
      for (const name of image.getAttributeNames()) {
        if (name !== 'src') old.setAttribute(name, image.getAttribute(name));
      }
      image.replaceWith(old);
    }
  }

  // Math, code and diagrams -----------------------------------------------------------------------

  async function renderMath(root) {
    const elements = root.querySelectorAll('[data-math-style]');
    if (elements.length === 0) return;
    try {
      await loadScript('vendor/katex.min.js');
      await loadScript('vendor/mhchem.min.js');
    } catch (_) {
      return;
    }
    for (const element of elements) {
      const source = element.textContent || '';
      const displayMode = element.dataset.mathStyle === 'display';
      try {
        window.katex.render(source, element, {
          displayMode,
          throwOnError: false,
          strict: 'ignore',
          trust: false,
          output: 'htmlAndMathml'
        });
        if (displayMode) element.closest('pre')?.classList.add('math-block');
      } catch (_) {
        element.textContent = source;
      }
    }
  }

  async function highlightCode(root) {
    const blocks = [...root.querySelectorAll('pre > code')].filter(code => !code.matches(DRAWN));
    if (blocks.length === 0) return;
    try {
      await loadScript('vendor/highlight.min.js');
    } catch (_) {
      return;
    }
    const hljs = window.hljs;
    for (const code of blocks) {
      const languageClass = [...code.classList].find(name => name.startsWith('language-'));
      const language = languageClass ? languageClass.slice('language-'.length) : '';
      const text = code.textContent || '';
      if (language ? !hljs.getLanguage(language) : text.length > AUTO_DETECT_LIMIT) {
        code.classList.add('nohighlight');
        continue;
      }
      const key = language + '\n' + text;
      let html = recall(highlightCache, key);
      if (html === undefined) {
        try {
          html = language ? hljs.highlight(text, { language, ignoreIllegals: true }).value : hljs.highlightAuto(text).value;
        } catch (_) {
          html = null;
        }
        remember(highlightCache, HIGHLIGHT_ENTRIES, key, html);
      }
      if (html === null) continue;
      code.innerHTML = html;
      code.classList.add('hljs');
    }
  }

  function diagramShell(pre, kind) {
    const shell = document.createElement('div');
    shell.className = 'diagram-shell ' + kind;
    const position = pre.getAttribute('data-sourcepos');
    if (position) shell.setAttribute('data-sourcepos', position);
    pre.replaceWith(shell);
    return shell;
  }

  function diagramFailed(pre, message) {
    pre.classList.add('diagram-source-fallback');
    const note = document.createElement('div');
    note.className = 'diagram-error';
    note.textContent = message || '';
    pre.before(note);
  }

  async function renderMermaid(root, token) {
    const blocks = [...root.querySelectorAll('pre > code.language-mermaid')];
    if (blocks.length === 0) return;
    try {
      await loadScript('vendor/mermaid.min.js');
    } catch (_) {
      return;
    }
    const mermaid = window.mermaid;
    if (mermaidTheme !== theme) {
      mermaid.initialize({
        startOnLoad: false,
        securityLevel: 'strict',
        suppressErrorRendering: true,
        theme: theme === 'dark' ? 'dark' : 'neutral',
        fontFamily: getComputedStyle(document.body).fontFamily,
        flowchart: { htmlLabels: false, useMaxWidth: true },
        sequence: { useMaxWidth: true }
      });
      mermaidTheme = theme;
    }
    // Mermaid lays out one diagram at a time; a diagram drawn before is taken from the cache.
    for (const [index, code] of blocks.entries()) {
      const source = code.textContent || '';
      const key = theme + '\n' + source;
      let svg = recall(mermaidCache, key);
      if (svg === undefined) {
        const id = `lithe-mermaid-${token}-${index}`;
        try {
          svg = (await mermaid.render(id, source)).svg;
        } catch (_) {
          svg = null;
        }
        document.getElementById('d' + id)?.remove();
        remember(mermaidCache, MERMAID_ENTRIES, key, svg);
        if (token !== renderToken) return;
      }
      const pre = code.parentElement;
      if (svg === null) {
        diagramFailed(pre, strings.mermaidFailed);
        continue;
      }
      diagramShell(pre, 'mermaid-shell').innerHTML = svg;
    }
  }

  async function loadMarkmap(root) {
    if (!root.querySelector('pre > code.language-markmap')) return;
    try {
      await loadScript('vendor/d3.min.js');
      await loadScript('vendor/markmap-lib.min.js');
      await loadScript('vendor/markmap-view.min.js');
    } catch (_) {
      // The blocks stay code.
    }
  }

  function escapeMarkmap(source) {
    return source.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
  }

  // renderMarkmaps draws the markmap blocks of the shown page; a markmap measures its text, so it
  // is drawn in place.
  function renderMarkmaps() {
    const markmap = window.markmap;
    if (!markmap?.Transformer || !markmap?.Markmap) return;
    for (const code of content.querySelectorAll('pre > code.language-markmap')) {
      const pre = code.parentElement;
      try {
        const transformed = new markmap.Transformer([]).transform(escapeMarkmap(code.textContent || ''));
        const shell = diagramShell(pre, 'markmap-shell');
        const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
        svg.setAttribute('aria-label', strings.markmap || '');
        shell.append(svg);
        markmaps.push(markmap.Markmap.create(svg, {
          autoFit: true,
          duration: 0,
          fitRatio: 0.92,
          maxWidth: 280,
          spacingHorizontal: 72,
          spacingVertical: 8
        }, transformed.root));
        for (const anchor of shell.querySelectorAll('a')) {
          if (!/^(https?:|mailto:|#)/i.test(anchor.getAttribute('href') || '')) anchor.removeAttribute('href');
        }
      } catch (_) {
        if (pre.isConnected) diagramFailed(pre, strings.markmapFailed);
      }
    }
  }

  // Rendering ------------------------------------------------------------------------------------

  async function render(revision, html) {
    const token = ++renderToken;
    shown = { revision, html };
    const template = document.createElement('template');
    template.innerHTML = html || '';
    const root = template.content;
    rewriteResources(root);
    await Promise.all([renderMath(root), highlightCode(root), loadMarkmap(root)]);
    if (token !== renderToken) return;
    await renderMermaid(root, token);
    if (token !== renderToken) return;
    for (const instance of markmaps) instance.destroy?.();
    markmaps = [];
    reuseImages(root);
    content.replaceChildren(root);
    renderMarkmaps();
    points = null;
    placeLine(topLine);
    post({ type: 'rendered', revision, headings: headings() });
  }

  function sourceLines(element) {
    const match = /^(\d+):\d+-(\d+):\d+/.exec(element.getAttribute('data-sourcepos') || '');
    return match ? [Number(match[1]), Number(match[2])] : null;
  }

  function headings() {
    const list = [];
    for (const heading of content.querySelectorAll('h1, h2, h3, h4, h5, h6')) {
      const lines = sourceLines(heading);
      const text = heading.textContent.replace(/\s+/g, ' ').trim();
      if (lines && text) list.push({ level: Number(heading.tagName[1]), text, line: lines[0] });
    }
    return list;
  }

  // Scrolling ------------------------------------------------------------------------------------

  // layout maps source lines to page offsets: each block adds its first line at its top and the
  // line after its last at its bottom, and lines between are interpolated. Footnotes are laid out
  // at the end whatever their source lines, so they are left out.
  function layout() {
    if (points) return points;
    margin = parseFloat(getComputedStyle(content).paddingTop) || 0;
    const scrollY = window.scrollY;
    const list = [];
    for (const element of content.querySelectorAll('[data-sourcepos]')) {
      if (!element.matches(BLOCKS) || element.closest('[data-footnotes], .footnotes')) continue;
      const lines = sourceLines(element);
      if (!lines) continue;
      const box = element.getBoundingClientRect();
      if (box.width === 0 && box.height === 0) continue;
      list.push({ line: lines[0], y: box.top + scrollY });
      list.push({ line: lines[1] + 1, y: box.bottom + scrollY });
    }
    list.sort((a, b) => a.line - b.line || a.y - b.y);
    points = [{ line: 1, y: margin }];
    for (const point of list) {
      if (point.y >= points[points.length - 1].y) points.push(point);
    }
    return points;
  }

  function yOfLine(line) {
    const map = layout();
    let low = 0;
    let high = map.length - 1;
    while (low < high) {
      const mid = (low + high + 1) >> 1;
      if (map[mid].line <= line) low = mid;
      else high = mid - 1;
    }
    const from = map[low];
    const to = map[low + 1];
    if (!to || from.line > line) return from.y;
    return from.y + (to.y - from.y) * (line - from.line) / (to.line - from.line);
  }

  function lineOfY(y) {
    const map = layout();
    let low = 0;
    let high = map.length - 1;
    while (low < high) {
      const mid = (low + high + 1) >> 1;
      if (map[mid].y <= y) low = mid;
      else high = mid - 1;
    }
    const from = map[low];
    const to = map[low + 1];
    if (!to || from.y > y || to.y === from.y) return from.line;
    return from.line + (to.line - from.line) * (y - from.y) / (to.y - from.y);
  }

  // placeLine scrolls the page so that source line is at its top, without reporting it back.
  function placeLine(line) {
    window.scrollTo(0, Math.max(0, yOfLine(line) - margin));
    expectedY = window.scrollY;
  }

  function onScroll() {
    if (expectedY !== null && Math.abs(window.scrollY - expectedY) < 1) return;
    expectedY = null;
    if (!reportFrame) reportFrame = requestAnimationFrame(report);
  }

  function report() {
    reportFrame = 0;
    topLine = lineOfY(window.scrollY + margin);
    post({ type: 'scrolled', line: topLine });
  }

  // A layout change (an image loaded, a diagram drawn, the page resized) keeps the line at the top.
  // The line the user scrolled to is read from the layout before the change.
  function onResize() {
    if (points && expectedY === null) topLine = lineOfY(window.scrollY + margin);
    points = null;
    placeLine(topLine);
  }

  // Links and images ------------------------------------------------------------------------------

  function jumpTo(fragment) {
    let id = fragment;
    try {
      id = decodeURIComponent(fragment);
    } catch (_) {
      // The fragment is used as written.
    }
    const target = document.getElementById(id) || document.getElementById('lithe-heading-' + id);
    if (!target) return;
    let block = target.closest('h1, h2, h3, h4, h5, h6') || target;
    while (block.parentElement && block.getClientRects().length === 0) block = block.parentElement;
    expectedY = null;
    window.scrollTo(0, Math.max(0, block.getBoundingClientRect().top + window.scrollY - margin));
  }

  function hrefOf(anchor) {
    const href = anchor.getAttribute('href');
    return href !== null ? href : anchor.getAttributeNS(XLINK, 'href');
  }

  function showImage(image) {
    fullImage.src = image.currentSrc || image.src;
    fullImage.alt = image.alt || '';
    viewer.hidden = false;
  }

  function closeImage() {
    viewer.hidden = true;
    fullImage.removeAttribute('src');
    fullImage.alt = '';
  }

  document.addEventListener('click', event => {
    const target = event.target instanceof Element ? event.target : null;
    if (!target) return;
    if (!viewer.hidden) {
      closeImage();
      return;
    }
    const anchor = target.closest('a');
    if (anchor) {
      const href = hrefOf(anchor);
      if (href === null) return;
      event.preventDefault();
      if (href.startsWith('#')) jumpTo(href.slice(1));
      else if (href.trim()) post({ type: 'link', href });
      return;
    }
    if (target instanceof HTMLImageElement && content.contains(target) && target.complete && target.naturalWidth > 0) {
      showImage(target);
    }
  });
  document.addEventListener('auxclick', event => {
    if (event.target instanceof Element && event.target.closest('a')) event.preventDefault();
  });
  document.addEventListener('keydown', event => {
    if (event.key === 'Escape' && !viewer.hidden) closeImage();
  });
  window.addEventListener('scroll', onScroll, { passive: true });
  new ResizeObserver(onResize).observe(content);

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
          applyStrings(message.strings);
          applyTheme(message.theme);
          break;
        case 'theme': {
          const before = theme;
          applyTheme(message.theme);
          if (theme !== before && content.querySelector('.mermaid-shell, .markmap-shell, .diagram-source-fallback')) {
            render(shown.revision, shown.html);
          }
          break;
        }
        case 'render':
          render(Number(message.revision) || 0, String(message.html || ''));
          break;
        case 'scroll':
          topLine = Math.max(1, Number(message.line) || 1);
          placeLine(topLine);
          break;
      }
    };
  }
  post({ type: 'ready' });
})();
