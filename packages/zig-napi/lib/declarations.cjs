"use strict";
// Adapted directly from napi-rs source at a713fcb377ee28be5abd7b6a560e3eb4f31444ca.
// MIT; see ../licenses/NAPI-RS-LICENSE.
// Source: cli/src/utils/typegen.ts (declaration specifiers and CJS barriers).
const { dirname, parse, relative, resolve } = require("node:path");
const IN_MEMORY_DECLARATION_FILE = "/__zig_napi__.d.ts";
function loadTypeScript() {
  return require("typescript");
}

function parseDeclarationFile(source) {
  const typeScript = loadTypeScript();
  return typeScript.createSourceFile(
    IN_MEMORY_DECLARATION_FILE,
    source,
    typeScript.ScriptTarget.Latest,
    true,
    typeScript.ScriptKind.TS,
  );
}

function rebaseDeclarationSpecifiers(source, sourcePath, destinationPath) {
  const references = collectRelativeDeclarationSpecifierReferences(source);
  const replacements = [];

  for (const reference of references) {
    const absoluteTarget = resolve(dirname(sourcePath), reference.specifier);
    let rebased = relative(dirname(destinationPath), absoluteTarget).replaceAll("\\", "/");
    if (!rebased.startsWith(".")) {
      rebased = `./${rebased}`;
    }
    replacements.push({
      start: reference.start,
      end: reference.end,
      replacement: rebased,
    });
  }

  let rebasedSource = source;
  for (const replacement of replacements
    .filter(
      (replacement, index, all) =>
        all.findIndex(
          (candidate) => candidate.start === replacement.start && candidate.end === replacement.end,
        ) === index,
    )
    .sort((left, right) => right.start - left.start)) {
    rebasedSource =
      rebasedSource.slice(0, replacement.start) +
      replacement.replacement +
      rebasedSource.slice(replacement.end);
  }
  return rebasedSource;
}

function commonJsDeclarationBarrier(source) {
  const typeScript = loadTypeScript();
  const sourceFile = parseDeclarationFile(source);

  const specifierBarrier = (literal) => {
    if (!literal.text.startsWith(".")) {
      return undefined;
    }
    const extension = parse(literal.text).ext.toLowerCase();
    if (extension !== "" && ![".js", ".jsx", ".ts", ".tsx"].includes(extension)) {
      return undefined;
    }
    return `a relative '${literal.text}' specifier`;
  };

  const hasResolutionMode = (attributes) =>
    attributes?.elements.some(
      (element) =>
        element.name.text === "resolution-mode" &&
        typeScript.isStringLiteral(element.value) &&
        (element.value.text === "import" || element.value.text === "require"),
    ) === true;

  const hasDefaultModifier = (node) =>
    typeScript.canHaveModifiers(node) === true &&
    typeScript
      .getModifiers(node)
      ?.some((modifier) => modifier.kind === typeScript.SyntaxKind.DefaultKeyword) === true;

  const isTypeOnlyStatement = (node) =>
    typeScript.isImportDeclaration(node)
      ? node.importClause?.isTypeOnly === true
      : node.isTypeOnly === true;

  let barrier;
  const visit = (node, insideModuleDeclaration) => {
    if (barrier !== undefined) {
      return;
    }
    if (!insideModuleDeclaration && hasDefaultModifier(node)) {
      barrier = "an `export default` declaration";
      return;
    }
    if (typeScript.isModuleDeclaration(node)) {
      if (typeScript.isStringLiteralLike(node.name)) {
        barrier = specifierBarrier(node.name);
      }
      if (barrier === undefined) {
        // A `declare module`/`declare global` block's statements describe that
        // module's own shape, so a `default` export inside one is honest; its
        // specifiers still resolve relative to this file.
        typeScript.forEachChild(node, (child) => visit(child, true));
      }
      return;
    }
    if (typeScript.isImportDeclaration(node) || typeScript.isExportDeclaration(node)) {
      if (node.attributes !== undefined && !isTypeOnlyStatement(node)) {
        barrier = "`with` attributes on a runtime module statement";
        return;
      }
      if (
        node.moduleSpecifier !== undefined &&
        typeScript.isStringLiteralLike(node.moduleSpecifier) &&
        !hasResolutionMode(node.attributes)
      ) {
        barrier = specifierBarrier(node.moduleSpecifier);
        if (barrier !== undefined) {
          return;
        }
      }
      if (
        !insideModuleDeclaration &&
        typeScript.isExportDeclaration(node) &&
        node.exportClause !== undefined &&
        ((typeScript.isNamedExports(node.exportClause) &&
          node.exportClause.elements.some((element) => element.name.text === "default")) ||
          (typeScript.isNamespaceExport(node.exportClause) &&
            node.exportClause.name.text === "default"))
      ) {
        barrier = "a `default` re-export";
      }
      return;
    }
    if (typeScript.isImportEqualsDeclaration(node)) {
      if (
        typeScript.isExternalModuleReference(node.moduleReference) &&
        typeScript.isStringLiteralLike(node.moduleReference.expression)
      ) {
        barrier = specifierBarrier(node.moduleReference.expression);
      }
      return;
    }
    if (typeScript.isExportAssignment(node)) {
      if (node.isExportEquals !== true && !insideModuleDeclaration) {
        barrier = "an `export default` declaration";
      }
      return;
    }
    if (typeScript.isImportTypeNode(node)) {
      if (
        typeScript.isLiteralTypeNode(node.argument) &&
        typeScript.isStringLiteralLike(node.argument.literal) &&
        !hasResolutionMode(node.attributes)
      ) {
        barrier = specifierBarrier(node.argument.literal);
      }
      // `import('pkg').T<import('./x.js').U>` nests another specifier in the
      // type arguments — keep descending.
      if (barrier === undefined) {
        typeScript.forEachChild(node, (child) => visit(child, insideModuleDeclaration));
      }
      return;
    }
    if (
      typeScript.isCallExpression(node) &&
      node.arguments.length >= 1 &&
      typeScript.isStringLiteralLike(node.arguments[0]) &&
      (node.expression.kind === typeScript.SyntaxKind.ImportKeyword ||
        (typeScript.isIdentifier(node.expression) && node.expression.text === "require"))
    ) {
      barrier = specifierBarrier(node.arguments[0]);
      return;
    }
    typeScript.forEachChild(node, (child) => visit(child, insideModuleDeclaration));
  };
  for (const statement of sourceFile.statements) {
    visit(statement, false);
  }
  if (barrier === undefined) {
    // `/// <reference types>` resolves through module resolution — a relative
    // name can diverge the same way a relative specifier can. `path`
    // references are file-path resolution and carry over honestly.
    for (const reference of typeScript.preProcessFile(source, true, true).typeReferenceDirectives) {
      if (reference.fileName.startsWith(".") && reference.resolutionMode === undefined) {
        barrier = `a relative '/// <reference types="${reference.fileName}" />' directive`;
        break;
      }
    }
  }
  return barrier;
}

function collectRelativeDeclarationSpecifierReferences(source) {
  const typeScript = loadTypeScript();
  const sourceFile = typeScript.createSourceFile(
    IN_MEMORY_DECLARATION_FILE,
    source,
    typeScript.ScriptTarget.Latest,
    true,
    typeScript.ScriptKind.TS,
  );
  const references = [];
  const addStringLiteral = (node) => {
    if (!node.text.startsWith(".")) {
      return;
    }
    references.push({
      start: node.getStart(sourceFile) + 1,
      end: node.end - 1,
      specifier: node.text,
    });
  };
  const visit = (node) => {
    if (
      (typeScript.isImportDeclaration(node) || typeScript.isExportDeclaration(node)) &&
      node.moduleSpecifier &&
      typeScript.isStringLiteralLike(node.moduleSpecifier)
    ) {
      addStringLiteral(node.moduleSpecifier);
    } else if (
      typeScript.isImportTypeNode(node) &&
      typeScript.isLiteralTypeNode(node.argument) &&
      typeScript.isStringLiteralLike(node.argument.literal)
    ) {
      addStringLiteral(node.argument.literal);
    } else if (typeScript.isModuleDeclaration(node) && typeScript.isStringLiteralLike(node.name)) {
      addStringLiteral(node.name);
    } else if (
      typeScript.isExternalModuleReference(node) &&
      node.expression &&
      typeScript.isStringLiteralLike(node.expression)
    ) {
      addStringLiteral(node.expression);
    } else if (
      typeScript.isCallExpression(node) &&
      node.arguments.length >= 1 &&
      typeScript.isStringLiteralLike(node.arguments[0]) &&
      (node.expression.kind === typeScript.SyntaxKind.ImportKeyword ||
        (typeScript.isIdentifier(node.expression) && node.expression.text === "require"))
    ) {
      addStringLiteral(node.arguments[0]);
    }
    typeScript.forEachChild(node, visit);
  };
  visit(sourceFile);

  const preprocessed = typeScript.preProcessFile(source, true, true);
  for (const reference of [
    ...preprocessed.referencedFiles,
    ...preprocessed.typeReferenceDirectives,
  ]) {
    if (reference.fileName.startsWith(".")) {
      references.push({
        start: reference.pos,
        end: reference.end,
        specifier: reference.fileName,
      });
    }
  }

  return references
    .filter(
      (reference, index, all) =>
        all.findIndex(
          (candidate) => candidate.start === reference.start && candidate.end === reference.end,
        ) === index,
    )
    .sort((left, right) => left.start - right.start);
}

module.exports = { rebaseDeclarationSpecifiers, commonJsDeclarationBarrier };
