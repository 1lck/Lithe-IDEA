const files = import.meta.glob("../../bundled/icon-themes/pierre/**/*.svg", {
  eager: true,
  import: "default",
  query: "?url",
}) as Record<string, string>;

export const assets = Object.fromEntries(
  Object.entries(files).map(([path, url]) => [path.replace("../../bundled/icon-themes/pierre/", ""), url]),
);
