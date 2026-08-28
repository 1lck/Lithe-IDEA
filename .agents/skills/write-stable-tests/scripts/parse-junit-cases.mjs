export function decodeXML(value) {
  return value
    .replaceAll("&quot;", '"')
    .replaceAll("&apos;", "'")
    .replaceAll("&lt;", "<")
    .replaceAll("&gt;", ">")
    .replaceAll("&amp;", "&");
}

export function parseJUnitCases(xml) {
  const cases = [];
  const pattern = /<testcase\b([^>]*?)(?:\/>|>[\s\S]*?<\/testcase>)/g;
  for (const match of xml.matchAll(pattern)) {
    const attributes = match[1];
    const name = attributes.match(/\bname="([^"]*)"/)?.[1] ?? "unknown";
    const className = attributes.match(/\bclassname="([^"]*)"/)?.[1] ?? "";
    const seconds = Number(attributes.match(/\btime="([0-9.]+)"/)?.[1] ?? 0);
    const body = match[0];
    const status = body.includes("<error")
      ? "error"
      : body.includes("<failure")
        ? "failed"
        : body.includes("<skipped")
          ? "skipped"
          : "passed";
    const detailsMatch = body.match(/<(?:failure|error)\b[^>]*>([\s\S]*?)<\/(?:failure|error)>/);
    const details = detailsMatch
      ? decodeXML(detailsMatch[1].replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, "$1").replace(/<[^>]+>/g, "").trim())
      : "";
    cases.push({
      name: decodeXML(className ? `${className} / ${name}` : name),
      status,
      durationMs: Math.round(seconds * 1000),
      ...(details ? { details } : {}),
    });
  }
  return cases;
}
