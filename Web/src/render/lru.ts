// Least-recently-used map bounded by a total weight (the caller's measure of size, e.g. characters held), so a cache
// of rendered output can never grow past a fixed amount whatever the documents look like.
export class LRU<V> {
  private readonly map = new Map<string, { value: V; weight: number }>();
  private total = 0;
  private budget: number;

  constructor(budget: number) {
    this.budget = budget;
  }

  /** A new budget; entries over it go at the next `set`. */
  resize(budget: number): void {
    this.budget = budget;
  }

  get(key: string): V | undefined {
    const hit = this.map.get(key);
    if (hit === undefined) return undefined;
    this.map.delete(key); // re-insert: Map iterates in insertion order, so the front is the least recently used
    this.map.set(key, hit);
    return hit.value;
  }

  /** The value kept for `key`, else `compute()`'s, kept from now on. Memo caches over document text use this: key and value
   *  (when a string) are stored as own copies (see ownCopy), so the cache never holds on to the text they were cut from. */
  getOrSet(key: string, compute: () => V, weight: (value: V) => number): V {
    const hit = this.get(key);
    if (hit !== undefined) return hit;
    let value = compute();
    if (typeof value === 'string') value = ownCopy(value) as V;
    this.set(ownCopy(key), value, weight(value));
    return value;
  }

  has(key: string): boolean {
    return this.map.has(key);
  }

  set(key: string, value: V, weight: number): void {
    const old = this.map.get(key);
    if (old !== undefined) {
      this.total -= old.weight;
      this.map.delete(key);
    }
    if (weight > this.budget) return; // bigger than the whole cache: not kept
    this.map.set(key, { value, weight });
    this.total += weight;
    for (const [k, e] of this.map) {
      if (this.total <= this.budget) break;
      this.map.delete(k);
      this.total -= e.weight;
    }
  }

  clear(): void {
    this.map.clear();
    this.total = 0;
  }

  get size(): number {
    return this.map.size;
  }

  get weight(): number {
    return this.total;
  }
}

// A flat copy of `s` sharing no storage with the string it was cut from. A slice keeps its whole parent alive (in V8 and in
// JavaScriptCore), so a cache holding slices of a document would hold every version of it; a concatenation is flattened
// into new storage when it is sliced.
export const ownCopy = (s: string): string => (s + ' ').slice(0, -1);
