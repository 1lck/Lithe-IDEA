/** Registration completes before dispatch, so abort cannot overtake creation
 * and disappear. The caller retains this promise through native cleanup. */
export async function prepareNativeBuildTool<T>(ports: {
  begin: () => Promise<string>;
  resolve: (operationID: string) => Promise<T>;
  cancel: (operationID: string) => Promise<void>;
}, signal?: AbortSignal): Promise<T> {
  signal?.throwIfAborted();
  const operationID = await ports.begin();
  let cancellation: Promise<void> | undefined;
  const cancel = () => {
    cancellation ??= ports.cancel(operationID);
    // Own a possibly rejected promise immediately; it is awaited below.
    void cancellation.catch(() => {});
  };
  signal?.addEventListener("abort", cancel, { once: true });
  try {
    if (signal?.aborted) { cancel(); signal.throwIfAborted(); }
    const result = await ports.resolve(operationID);
    signal?.throwIfAborted();
    return result;
  } finally {
    signal?.removeEventListener("abort", cancel);
    // Also retire a registration whose resolve IPC failed before dispatch.
    // Reject failed acknowledgements instead of reporting cleanup as successful.
    cancel();
    await cancellation;
  }
}
