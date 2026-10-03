// Test-only flavor chunk: counts its own evaluations and tags paragraphs with that count.
globalThis.testChunkLoads = (globalThis.testChunkLoads || 0) + 1;
MacDown2.flavors.register('test', (md) => {
  md.core.ruler.push('test_class', (state) => {
    for (const t of state.tokens) if (t.type === 'paragraph_open') t.attrJoin('class', `test-flavor-${globalThis.testChunkLoads}`);
  });
});
