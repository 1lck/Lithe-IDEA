const DEFAULT_GIT_READ_BATCH_SIZE = 4;

const yieldToRenderer = () =>
  new Promise<void>((resolve) => {
    if (typeof globalThis.requestAnimationFrame === "function") {
      globalThis.requestAnimationFrame(() => resolve());
      return;
    }
    globalThis.queueMicrotask(resolve);
  });

export async function mapGitReadsInBatches<T, R>(
  items: readonly T[],
  operation: (item: T, index: number) => Promise<R>,
  options: { batchSize?: number; yieldControl?: () => Promise<void> } = {},
): Promise<R[]> {
  const batchSize = Math.max(1, options.batchSize ?? DEFAULT_GIT_READ_BATCH_SIZE);
  const results: R[] = [];
  for (let offset = 0; offset < items.length; offset += batchSize) {
    const batch = items.slice(offset, offset + batchSize);
    results.push(
      ...(await Promise.all(batch.map((item, index) => operation(item, offset + index)))),
    );
    if (offset + batch.length < items.length) {
      await (options.yieldControl ?? yieldToRenderer)();
    }
  }
  return results;
}
