/** Requests answered within this window feel immediate and show nothing. */
export const SLOW_REQUEST_NOTICE_DELAY_MS = 300;

export interface SlowRequestNotice {
  show: () => void;
  dismiss: () => void;
}

type Timers = {
  setTimeout: (callback: () => void, delay: number) => unknown;
  clearTimeout: (handle: unknown) => void;
};

const browserTimers: Timers = {
  setTimeout: (callback, delay) => globalThis.setTimeout(callback, delay),
  clearTimeout: (handle) => globalThis.clearTimeout(handle as ReturnType<typeof setTimeout>),
};

/**
 * Shows `notice` only while `request` is still running after the delay, so a
 * navigation that waits on a busy language server says so instead of looking
 * like an ignored keystroke.
 */
export async function withSlowRequestNotice<T>(
  request: Promise<T>,
  notice: SlowRequestNotice,
  delayMs = SLOW_REQUEST_NOTICE_DELAY_MS,
  timers: Timers = browserTimers,
): Promise<T> {
  let shown = false;
  const handle = timers.setTimeout(() => {
    shown = true;
    notice.show();
  }, delayMs);
  try {
    return await request;
  } finally {
    timers.clearTimeout(handle);
    if (shown) notice.dismiss();
  }
}
