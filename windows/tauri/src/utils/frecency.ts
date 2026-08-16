/**
 * Frecency algorithm for ranking items based on frequency and recency
 * Combines access frequency with how recently an item was accessed
 */

const HALF_LIFE_DAYS = 7; // Items lose half their recency value every 7 days
const FREQUENCY_WEIGHT = 0.7; // How much frequency matters vs recency (0-1)
const RECENCY_WEIGHT = 1 - FREQUENCY_WEIGHT;

/**
 * Calculate frecency score for an item
 * @param accessCount - Number of times the item has been accessed
 * @param lastAccessTime - When the item was last accessed
 * @returns Frecency score (higher is better)
 */
export function calculateFrecencyScore(accessCount: number, lastAccessTime: Date | string): number {
  const now = new Date();
  const lastAccess = typeof lastAccessTime === "string" ? new Date(lastAccessTime) : lastAccessTime;

  // Calculate days since last access
  const daysSinceAccess = (now.getTime() - lastAccess.getTime()) / (1000 * 60 * 60 * 24);

  // Frequency factor: logarithmic growth to prevent domination by very frequently accessed items
  const frequencyFactor = Math.log10(accessCount + 1); // +1 to handle 0 access count

  // Recency factor: exponential decay based on half-life
  const decayRate = Math.log(2) / HALF_LIFE_DAYS;
  const recencyFactor = Math.exp(-decayRate * daysSinceAccess);

  // Combine factors with weights
  const score = FREQUENCY_WEIGHT * frequencyFactor + RECENCY_WEIGHT * recencyFactor;

  // Normalize to 0-100 range for easier interpretation
  return Math.min(100, score * 100);
}
