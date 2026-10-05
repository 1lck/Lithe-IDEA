// Block commits while a diff selection write (including its confirming read)
// is pending. A closed preview releases its lease only after the write settles.
let pending = 0;
const listeners = new Set<() => void>();
export const commitDiffWritePending = () => pending > 0;
export function subscribeCommitDiffWrites(listener: () => void) {
  listeners.add(listener);
  return () => { listeners.delete(listener); };
}
export function beginCommitDiffWrite() {
  let released = false;
  pending++;
  listeners.forEach(listener => listener());
  return () => {
    if (released) return;
    released = true;
    pending--;
    listeners.forEach(listener => listener());
  };
}
