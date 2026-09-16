export interface LitheModelUriParts {
  scheme: "lithe";
  authority: "editor";
  path: string;
  query: string;
}

export function createLitheModelUriParts(
  bufferId: string | undefined,
  filePath: string,
  displayPath = filePath,
): LitheModelUriParts {
  const sanitizedPath = displayPath.replace(/^\/+/, "");
  const path = sanitizedPath.length > 0 ? sanitizedPath : `${bufferId ?? "untitled"}.txt`;
  const query = new URLSearchParams();
  if (bufferId) query.set("buffer", bufferId);
  if (displayPath !== filePath) query.set("file", filePath);
  return {
    scheme: "lithe",
    authority: "editor",
    path: `/${path}`,
    query: query.toString(),
  };
}

export function filePathFromLitheModelUri(path: string, query: string): string {
  const filePath = new URLSearchParams(query).get("file");
  if (filePath) return filePath;

  const decodedPath = decodeURIComponent(path);
  if (/^\/[A-Za-z]:\//.test(decodedPath)) return decodedPath.slice(1);
  return decodedPath;
}
