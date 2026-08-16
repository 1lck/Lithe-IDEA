export const REQUEST_WINDOW_CLOSE_EVENT = "lithe:request-window-close";

export function requestWindowClose() {
  window.dispatchEvent(new CustomEvent(REQUEST_WINDOW_CLOSE_EVENT));
}
