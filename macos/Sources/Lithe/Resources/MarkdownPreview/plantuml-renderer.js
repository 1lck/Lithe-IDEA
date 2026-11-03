// The engine owns PlantUML syntax. This host grants no file/include/stdlib
// capabilities; the isolated page's CSP also denies network and frames.
let deniedResource = false;
globalThis.PLANTUML_FILE_LOADER = (_path, _from, _ok, fail) => {
  deniedResource = true;
  fail('External files are unavailable');
};
globalThis.PLANTUML_STDLIB_LOADER = (_path, _ok, fail) => {
  deniedResource = true;
  fail('Optional libraries are unavailable');
};

window.LithePlantUML = Object.freeze({
  async render(source, dark) {
    const { renderToString } = await import('./vendor/plantuml/plantuml.js');
    return new Promise((resolve, reject) => {
      renderToString(source.split(/\r\n|\r|\n/), svg => {
        if (deniedResource) reject('diagramResourceDenied');
        else resolve(svg);
      }, reject, { dark, maxSvgSize: 4096 });
    });
  }
});
