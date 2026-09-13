/**
 * API document metadata: navigation titles, summaries, and the order the
 * documents have always been published in.
 *
 * The bodies live in `src/content/api/*.md` and are never duplicated here;
 * this module only carries the navigation labels and grouping the site used
 * before the migration, so ordering and sidebar structure stay identical.
 */

export type ApiDocMeta = {
  /** Content collection id and URL segment. `overview` is served at `/api/`. */
  id: string;
  /** Sidebar and pager label. */
  title: string;
  /** Meta description for the document page. */
  summary: string;
};

export type ApiDocGroup = {
  title: string;
  docs: ApiDocMeta[];
};

export const apiDocGroups: ApiDocGroup[] = [
  {
    title: "Entry",
    docs: [
      {
        id: "overview",
        title: "Overview",
        summary: "What the public API exports and how the pieces fit together.",
      },
      {
        id: "conversion-model",
        title: "Conversion Model",
        summary: "Automatic JavaScript-to-Zig conversion and TypeScript declaration mapping.",
      },
      {
        id: "module-registration",
        title: "Module Registration",
        summary: "How exported Zig declarations become JavaScript module exports.",
      },
    ],
  },
  {
    title: "Build",
    docs: [
      {
        id: "build-openharmony",
        title: "OpenHarmony Build",
        summary: "Build shared libraries for ArkTS and OpenHarmony targets.",
      },
      {
        id: "build-node",
        title: "Node Addon Build",
        summary: "Build platform-specific Node.js .node addons.",
      },
      {
        id: "declaration-generation",
        title: "Declaration Generation",
        summary: "Generate index.d.ts from the same addon root.",
      },
    ],
  },
  {
    title: "TypeScript",
    docs: [
      {
        id: "dts-overrides",
        title: "d.ts Overrides",
        summary: "Override the generated TypeScript shape without changing runtime values.",
      },
      {
        id: "versioning",
        title: "Versioning",
        summary: "Node-API versions, experimental mode, and gated wrappers.",
      },
    ],
  },
  {
    title: "Values",
    docs: [
      {
        id: "values-primitives",
        title: "Primitive Values",
        summary: "Numbers, strings, booleans, bigint, null, undefined, and raw N-API values.",
      },
      {
        id: "values-objects",
        title: "Objects And Arrays",
        summary: "Object, Array, Promise, Env, and property helpers.",
      },
      {
        id: "binary-data",
        title: "Binary Data",
        summary: "Buffer, ArrayBuffer, TypedArray, and DataView wrappers.",
      },
    ],
  },
  {
    title: "Control Flow",
    docs: [
      {
        id: "callback-functions",
        title: "Functions",
        summary: "Function wrappers, callback info, references, and thread-safe calls.",
      },
      {
        id: "async-runtime",
        title: "Async Runtime",
        summary: "Async descriptors, event emission, cancellation, AbortSignal, and workers.",
      },
    ],
  },
  {
    title: "Native State",
    docs: [
      {
        id: "classes-ownership",
        title: "Ownership",
        summary: "Classes, references, externals, native wraps, and allocator hooks.",
      },
      {
        id: "errors-results",
        title: "Errors",
        summary: "JavaScript errors, typed errors, status values, and Result(T).",
      },
    ],
  },
];

/** All documents in published order; this order drives prev/next pagination. */
export const apiDocs: ApiDocMeta[] = apiDocGroups.flatMap((group) => group.docs);

/** The document served at `/api/`. */
export const overviewDoc: ApiDocMeta = apiDocs.find((doc) => doc.id === "overview")!;

export function getApiDoc(id: string): ApiDocMeta {
  return apiDocs.find((doc) => doc.id === id) ?? overviewDoc;
}

export function getApiDocNeighbours(id: string): {
  previous?: ApiDocMeta;
  next?: ApiDocMeta;
} {
  const index = apiDocs.findIndex((doc) => doc.id === id);
  if (index < 0) return {};
  return {
    previous: index > 0 ? apiDocs[index - 1] : undefined,
    next: index < apiDocs.length - 1 ? apiDocs[index + 1] : undefined,
  };
}
