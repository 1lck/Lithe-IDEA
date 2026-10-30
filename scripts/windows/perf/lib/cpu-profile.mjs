/** Sums a V8 CPU profile's self time per function, longest first. */
export function topSelfTime(profile, limit) {
  const nodes = new Map(profile.nodes.map((node) => [node.id, node]));
  const totals = new Map();
  profile.samples.forEach((id, index) => {
    const { functionName, url, lineNumber } = nodes.get(id).callFrame;
    const key = `${functionName}|${url}|${lineNumber}`;
    const entry = totals.get(key) ?? {
      name: functionName || "(anonymous)",
      url: url ? `${url.split("/").pop()}:${lineNumber + 1}` : "",
      microseconds: 0,
    };
    entry.microseconds += profile.timeDeltas[index];
    totals.set(key, entry);
  });
  return [...totals.values()]
    .filter((entry) => entry.name !== "(idle)" && entry.name !== "(program)")
    .sort((left, right) => right.microseconds - left.microseconds)
    .slice(0, limit)
    .map(({ name, url, microseconds }) => ({ name, url, milliseconds: microseconds / 1000 }));
}
