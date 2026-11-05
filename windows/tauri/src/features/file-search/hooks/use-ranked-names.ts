import { useEffect, useRef, useState } from "react";
import { rankNames, type RankNameCandidate } from "../lib/rank-names";

const identities = new WeakMap<object, number>();
let nextIdentity = 0;

function identityOf(value: object): number {
  let id = identities.get(value);
  if (id === undefined) {
    id = ++nextIdentity;
    identities.set(value, id);
  }
  return id;
}

/**
 * Filters and orders `items` by name with Rust Core (`workspace.rankNames`).
 *
 * Returns `null` for a blank query (the caller shows the unfiltered list). Otherwise it returns
 * the latest ranked list: identical requests are sent once, an answer for an outdated query is
 * dropped, and the previous list stays until the next one arrives.
 */
export function useRankedNames<T>(
  items: readonly T[],
  query: string,
  toCandidate: (item: T) => RankNameCandidate,
): T[] | null {
  const trimmed = query.trim();
  const [ranked, setRanked] = useState<T[]>([]);
  const toCandidateRef = useRef(toCandidate);
  toCandidateRef.current = toCandidate;
  const issuedKeyRef = useRef<string | null>(null);
  const latestRequestRef = useRef(0);

  useEffect(() => {
    if (!trimmed) {
      issuedKeyRef.current = null;
      latestRequestRef.current += 1;
      return;
    }
    const key = JSON.stringify([trimmed, identityOf(items)]);
    if (issuedKeyRef.current === key) return;
    issuedKeyRef.current = key;
    const request = ++latestRequestRef.current;
    rankNames(
      trimmed,
      items.map((item) => toCandidateRef.current(item)),
      {},
      Math.max(items.length, 1),
    )
      .then((hits) => {
        if (request !== latestRequestRef.current) return;
        setRanked(hits.flatMap((hit) => (items[hit.index] ? [items[hit.index]!] : [])));
      })
      .catch((error) => {
        if (request === latestRequestRef.current) issuedKeyRef.current = null;
        console.error("Name ranking failed:", error);
      });
  }, [items, trimmed]);

  return trimmed ? ranked : null;
}
