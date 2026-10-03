/*
 * yaml.ts (trimmed to loadYaml)
 *
 * Copyright (C) 2022-2026 by Posit Software, PBC
 */

import * as jsYaml from "js-yaml";

/**
 * Parse a single YAML document.
 *
 * Like js-yaml's `load()`, except that empty input (empty, whitespace-only or
 * comment-only) returns `undefined` rather than throwing, as js-yaml 4 did.
 * Invalid YAML and multi-document input still throw.
 */
export function loadYaml(src: string, options?: jsYaml.LoadOptions): unknown {
  const docs = jsYaml.loadAll(src, options);
  if (docs.length > 1) {
    throw new jsYaml.YAMLException(
      "expected a single document in the stream, but found more",
    );
  }
  return docs[0];
}
