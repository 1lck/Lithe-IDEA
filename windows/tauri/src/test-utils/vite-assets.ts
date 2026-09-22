import { plugin } from "bun";

// Workflow tests import UI modules transitively but do not render asset bytes.
// Match Vite's SVG URL imports so Bun does not parse XML as JavaScript.
plugin({
  name: "vite-svg-urls",
  setup(build) {
    build.onLoad({ filter: /\.svg(?:\?url)?$/ }, ({ path }) => ({
      contents: `export default ${JSON.stringify(path)};`,
      loader: "js",
    }));
  },
});
