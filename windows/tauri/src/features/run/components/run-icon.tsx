export function JavaCupIcon({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 16 16" width="14" height="14" fill="none" className={className} aria-hidden>
      <path
        d="M3.5 5.5h7.25c.97 0 1.75.78 1.75 1.75S11.72 9 10.75 9H10.5"
        stroke="currentColor"
        strokeWidth="1.15"
        strokeLinecap="round"
      />
      <path
        d="M3.75 5.5h6.5v4.25a2.75 2.75 0 0 1-2.75 2.75h-1A2.75 2.75 0 0 1 3.75 9.75V5.5Z"
        stroke="currentColor"
        strokeWidth="1.15"
      />
      <path d="M4.25 13.25h5.5" stroke="currentColor" strokeWidth="1.15" strokeLinecap="round" />
    </svg>
  );
}
