import type { ComponentType } from "react";

import AsyncRuntime, { headings as asyncRuntimeHeadings } from "./async-runtime.md";
import BinaryData, { headings as binaryDataHeadings } from "./binary-data.md";
import BuildNode, { headings as buildNodeHeadings } from "./build-node.md";
import BuildOpenHarmony, { headings as buildOpenHarmonyHeadings } from "./build-openharmony.md";
import CallbackFunctions, { headings as callbackFunctionsHeadings } from "./callback-functions.md";
import ClassesOwnership, { headings as classesOwnershipHeadings } from "./classes-ownership.md";
import ConversionModel, { headings as conversionModelHeadings } from "./conversion-model.md";
import DeclarationGeneration, {
  headings as declarationGenerationHeadings,
} from "./declaration-generation.md";
import DtsOverrides, { headings as dtsOverridesHeadings } from "./dts-overrides.md";
import ErrorsResults, { headings as errorsResultsHeadings } from "./errors-results.md";
import ModuleRegistration, {
  headings as moduleRegistrationHeadings,
} from "./module-registration.md";
import Overview, { headings as overviewHeadings } from "./overview.md";
import ValuesObjects, { headings as valuesObjectsHeadings } from "./values-objects.md";
import ValuesPrimitives, { headings as valuesPrimitivesHeadings } from "./values-primitives.md";
import Versioning, { headings as versioningHeadings } from "./versioning.md";

export type ApiHeading = {
  depth: number;
  slug: string;
  text: string;
};

export type ApiMarkdownSection = {
  id: string;
  title: string;
  summary: string;
  headings: ReadonlyArray<ApiHeading>;
  Component: ComponentType;
};

export type ApiMarkdownGroup = {
  title: string;
  sections: ApiMarkdownSection[];
};

const overviewSection: ApiMarkdownSection = {
  id: "overview",
  title: "Overview",
  summary: "What the public API exports and how the pieces fit together.",
  headings: overviewHeadings,
  Component: Overview,
};

export const apiMarkdownGroups: ApiMarkdownGroup[] = [
  {
    title: "Entry",
    sections: [
      overviewSection,
      {
        id: "conversion-model",
        title: "Conversion Model",
        summary: "Automatic JavaScript-to-Zig conversion and TypeScript declaration mapping.",
        headings: conversionModelHeadings,
        Component: ConversionModel,
      },
      {
        id: "module-registration",
        title: "Module Registration",
        summary: "How exported Zig declarations become JavaScript module exports.",
        headings: moduleRegistrationHeadings,
        Component: ModuleRegistration,
      },
    ],
  },
  {
    title: "Build",
    sections: [
      {
        id: "build-openharmony",
        title: "OpenHarmony Build",
        summary: "Build shared libraries for ArkTS and OpenHarmony targets.",
        headings: buildOpenHarmonyHeadings,
        Component: BuildOpenHarmony,
      },
      {
        id: "build-node",
        title: "Node Addon Build",
        summary: "Build platform-specific Node.js .node addons.",
        headings: buildNodeHeadings,
        Component: BuildNode,
      },
      {
        id: "declaration-generation",
        title: "Declaration Generation",
        summary: "Generate index.d.ts from the same addon root.",
        headings: declarationGenerationHeadings,
        Component: DeclarationGeneration,
      },
    ],
  },
  {
    title: "TypeScript",
    sections: [
      {
        id: "dts-overrides",
        title: "d.ts Overrides",
        summary: "Override the generated TypeScript shape without changing runtime values.",
        headings: dtsOverridesHeadings,
        Component: DtsOverrides,
      },
      {
        id: "versioning",
        title: "Versioning",
        summary: "Node-API versions, experimental mode, and gated wrappers.",
        headings: versioningHeadings,
        Component: Versioning,
      },
    ],
  },
  {
    title: "Values",
    sections: [
      {
        id: "values-primitives",
        title: "Primitive Values",
        summary: "Numbers, strings, booleans, bigint, null, undefined, and raw N-API values.",
        headings: valuesPrimitivesHeadings,
        Component: ValuesPrimitives,
      },
      {
        id: "values-objects",
        title: "Objects And Arrays",
        summary: "Object, Array, Promise, Env, and property helpers.",
        headings: valuesObjectsHeadings,
        Component: ValuesObjects,
      },
      {
        id: "binary-data",
        title: "Binary Data",
        summary: "Buffer, ArrayBuffer, TypedArray, and DataView wrappers.",
        headings: binaryDataHeadings,
        Component: BinaryData,
      },
    ],
  },
  {
    title: "Control Flow",
    sections: [
      {
        id: "callback-functions",
        title: "Functions",
        summary: "Function wrappers, callback info, references, and thread-safe calls.",
        headings: callbackFunctionsHeadings,
        Component: CallbackFunctions,
      },
      {
        id: "async-runtime",
        title: "Async Runtime",
        summary: "Async descriptors, event emission, cancellation, AbortSignal, and workers.",
        headings: asyncRuntimeHeadings,
        Component: AsyncRuntime,
      },
    ],
  },
  {
    title: "Native State",
    sections: [
      {
        id: "classes-ownership",
        title: "Ownership",
        summary: "Classes, references, externals, native wraps, and allocator hooks.",
        headings: classesOwnershipHeadings,
        Component: ClassesOwnership,
      },
      {
        id: "errors-results",
        title: "Errors",
        summary: "JavaScript errors, typed errors, status values, and Result(T).",
        headings: errorsResultsHeadings,
        Component: ErrorsResults,
      },
    ],
  },
];

export const apiMarkdownSections = apiMarkdownGroups.flatMap((group) => group.sections);

export function getApiSection(id: string) {
  return apiMarkdownSections.find((section) => section.id === id) ?? overviewSection;
}
