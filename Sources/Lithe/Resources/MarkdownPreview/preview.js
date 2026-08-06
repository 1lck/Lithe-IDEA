(() => {
  'use strict';

  const content = document.getElementById('content');
  const toc = document.getElementById('toc');
  const tocList = document.getElementById('toc-list');
  const tocToggle = document.getElementById('toc-toggle');
  const viewer = document.getElementById('image-viewer');
  const fullImage = document.getElementById('image-full');
  const imageClose = document.getElementById('image-close');
  let renderVersion = 0;
  let markmaps = [];
  let scrollCommandVersion = 0;
  let suppressScrollReportsUntil = 0;
  let scrollReportFrame = 0;

  function setTheme(theme) {
    document.documentElement.dataset.theme = theme === 'light' ? 'light' : 'dark';
  }

  function scopedAssetURL(rawValue) {
    const raw = (rawValue || '').trim();
    if (!raw || raw.startsWith('#')) return raw;
    if (/^(https?:|data:|lithe-resource:)/i.test(raw)) return raw;
    if (raw.startsWith('//')) return `https:${raw}`;
    if (/^[a-z][a-z0-9+.-]*:/i.test(raw)) return '';

    const scope = raw.startsWith('/') ? 'workspace' : 'document';
    const path = raw.startsWith('/') ? raw.slice(1) : raw;
    return `lithe-resource://${scope}?path=${encodeURIComponent(path)}`;
  }

  function rewriteLocalAssets() {
    content.querySelectorAll('img[src], video[src], audio[src], source[src]').forEach(element => {
      const scoped = scopedAssetURL(element.getAttribute('src'));
      if (scoped) element.setAttribute('src', scoped);
      else element.removeAttribute('src');
    });
  }

  function renderMath() {
    if (!window.katex) return;
    content.querySelectorAll('[data-math-style]').forEach(element => {
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
        if (displayMode && element.closest('pre')) element.closest('pre').classList.add('math-block');
      } catch (_) {
        element.textContent = source;
      }
    });
  }

  function highlightCode() {
    if (!window.hljs) return;
    content.querySelectorAll('pre code').forEach(code => {
      if (code.matches('.language-mermaid, .language-markmap, [data-math-style]')) return;
      const languageClass = Array.from(code.classList).find(name => name.startsWith('language-'));
      const language = languageClass?.slice('language-'.length);
      if (language && !window.hljs.getLanguage(language)) {
        code.classList.add('nohighlight');
        return;
      }
      try {
        window.hljs.highlightElement(code);
      } catch (_) {
        // Unknown language identifiers remain readable as plain code.
      }
    });
  }

  async function renderMermaid(version) {
    if (!window.mermaid) return;
    const dark = document.documentElement.dataset.theme === 'dark';
    window.mermaid.initialize({
      startOnLoad: false,
      securityLevel: 'strict',
      theme: dark ? 'dark' : 'neutral',
      fontFamily: '-apple-system, BlinkMacSystemFont, Segoe UI, sans-serif',
      flowchart: { htmlLabels: false, useMaxWidth: true },
      sequence: { useMaxWidth: true }
    });

    const diagrams = Array.from(content.querySelectorAll('pre > code.language-mermaid'));
    await Promise.all(diagrams.map(async (code, index) => {
      const source = code.textContent || '';
      const pre = code.parentElement;
      try {
        const result = await window.mermaid.render(`lithe-mermaid-${version}-${index}`, source);
        if (version !== renderVersion) return;
        const shell = document.createElement('div');
        shell.className = 'diagram-shell mermaid-shell';
        shell.innerHTML = result.svg;
        pre.replaceWith(shell);
        result.bindFunctions?.(shell);
      } catch (_) {
        pre.classList.add('diagram-source-fallback');
        const message = document.createElement('div');
        message.className = 'diagram-error';
        message.textContent = 'Mermaid could not render this diagram. Showing its source instead.';
        pre.before(message);
      }
    }));
  }

  function escapedMarkmapSource(source) {
    return source.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
  }

  function renderMarkmaps() {
    markmaps.forEach(instance => instance.destroy?.());
    markmaps = [];
    if (!window.markmap?.Transformer || !window.markmap?.Markmap) return;

    content.querySelectorAll('pre > code.language-markmap').forEach(code => {
      const pre = code.parentElement;
      try {
        const transformer = new window.markmap.Transformer([]);
        const transformed = transformer.transform(escapedMarkmapSource(code.textContent || ''));
        const shell = document.createElement('div');
        shell.className = 'diagram-shell markmap-shell';
        const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
        svg.setAttribute('aria-label', 'Markmap diagram');
        shell.append(svg);
        pre.replaceWith(shell);
        const instance = window.markmap.Markmap.create(svg, {
          autoFit: true,
          duration: 0,
          fitRatio: 0.92,
          maxWidth: 280,
          spacingHorizontal: 72,
          spacingVertical: 8
        }, transformed.root);
        markmaps.push(instance);
        shell.querySelectorAll('a').forEach(anchor => {
          const href = anchor.getAttribute('href') || '';
          if (!/^(https?:|mailto:|#)/i.test(href)) anchor.removeAttribute('href');
        });
      } catch (_) {
        pre.classList.add('diagram-source-fallback');
        const message = document.createElement('div');
        message.className = 'diagram-error';
        message.textContent = 'Markmap could not render this diagram. Showing its source instead.';
        pre.before(message);
      }
    });
  }

  function buildTOC() {
    tocList.replaceChildren();
    const headings = Array.from(content.querySelectorAll('h1, h2, h3'));
    const ids = new Set();
    headings.forEach((heading, index) => {
      let id = heading.id || `lithe-heading-${index + 1}`;
      const base = id;
      let suffix = 2;
      while (ids.has(id)) id = `${base}-${suffix++}`;
      ids.add(id);
      heading.id = id;

      const link = document.createElement('a');
      link.href = `#${id}`;
      link.dataset.level = heading.tagName.slice(1);
      link.textContent = heading.textContent.trim() || `Section ${index + 1}`;
      link.addEventListener('click', event => {
        event.preventDefault();
        heading.scrollIntoView({ behavior: 'smooth', block: 'start' });
        closeTOC();
      });
      tocList.append(link);
    });

    tocToggle.hidden = headings.length === 0;
    if (headings.length === 0) closeTOC();
  }

  function closeTOC() {
    toc.hidden = true;
    tocToggle.setAttribute('aria-expanded', 'false');
  }

  function toggleTOC() {
    const opening = toc.hidden;
    toc.hidden = !opening;
    tocToggle.setAttribute('aria-expanded', String(opening));
  }

  function closeImage() {
    viewer.hidden = true;
    fullImage.removeAttribute('src');
    fullImage.alt = '';
  }

  function setupImages() {
    content.querySelectorAll('img').forEach(image => {
      image.loading = 'lazy';
      image.addEventListener('click', () => {
        if (!image.currentSrc && !image.src) return;
        fullImage.src = image.currentSrc || image.src;
        fullImage.alt = image.alt || '';
        viewer.hidden = false;
      });
    });
  }

  function currentScrollRatio() {
    const extent = Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
    return extent > 0 ? window.scrollY / extent : 0;
  }

  function restoreScrollRatio(ratio) {
    const extent = Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
    window.scrollTo(0, Math.max(0, Math.min(1, ratio)) * extent);
  }

  function reportScrollRatio() {
    scrollReportFrame = 0;
    if (performance.now() < suppressScrollReportsUntil) return;
    const handler = window.webkit?.messageHandlers?.markdownScrollSync;
    handler?.postMessage(currentScrollRatio());
  }

  function scheduleScrollReport() {
    if (scrollReportFrame) return;
    scrollReportFrame = requestAnimationFrame(reportScrollRatio);
  }

  function setScrollRatio(ratio) {
    scrollCommandVersion += 1;
    suppressScrollReportsUntil = performance.now() + 120;
    restoreScrollRatio(Number.isFinite(ratio) ? ratio : 0);
    return true;
  }

  async function update(payload) {
    const version = ++renderVersion;
    const initialScrollCommandVersion = scrollCommandVersion;
    const scrollRatio = currentScrollRatio();
    setTheme(payload?.appearance);
    content.innerHTML = payload?.html || '';
    rewriteLocalAssets();
    renderMath();
    highlightCode();
    renderMarkmaps();
    buildTOC();
    setupImages();
    await renderMermaid(version);
    if (version !== renderVersion) return false;
    if (initialScrollCommandVersion === scrollCommandVersion) {
      requestAnimationFrame(() => restoreScrollRatio(scrollRatio));
    }
    return true;
  }

  tocToggle.addEventListener('click', event => {
    event.stopPropagation();
    toggleTOC();
  });
  document.addEventListener('click', event => {
    if (!toc.hidden && !toc.contains(event.target) && event.target !== tocToggle) closeTOC();
  });
  viewer.addEventListener('click', event => {
    if (event.target === viewer || event.target === imageClose) closeImage();
  });
  imageClose.addEventListener('click', closeImage);
  document.addEventListener('keydown', event => {
    if (event.key === 'Escape') {
      closeTOC();
      closeImage();
    }
  });
  window.addEventListener('scroll', scheduleScrollReport, { passive: true });

  window.LithePreview = Object.freeze({ update, setScrollRatio });
})();
