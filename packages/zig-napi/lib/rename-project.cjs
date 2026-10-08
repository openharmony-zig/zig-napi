const fs = require("node:fs");
const path = require("node:path");

// Zig projects do not have the Cargo.toml that napi-rs rename requires.
// Stage all owned files, validate destinations, and roll back a failed write.
module.exports = function renameProject(cwd, flags) {
  cwd = fs.realpathSync(cwd);
  const owned = (file) => {
    const resolved = fs.realpathSync(path.resolve(cwd, file));
    const relative = path.relative(cwd, resolved);
    if (relative === ".." || relative.startsWith(".." + path.sep) || path.isAbsolute(relative))
      throw new Error(`Rename path leaves the project: ${file}`);
    return resolved;
  };
  const packagePath = owned(flags.packageJsonPath || "package.json");
  const pkg = JSON.parse(fs.readFileSync(packagePath, "utf8"));
  const configPath = flags.configPath ? owned(flags.configPath) : undefined;
  const config = {
    ...pkg.napi,
    ...(configPath ? JSON.parse(fs.readFileSync(configPath, "utf8")) : {}),
  };
  const oldBinary = config.binaryName;
  if (
    typeof oldBinary !== "string" ||
    !oldBinary ||
    (config.binaryNames && config.binaryNames.length)
  )
    throw new Error("Rename requires a single napi.binaryName");
  const oldPackage = config.packageName || pkg.name;
  const binary = flags.binaryName || oldBinary;
  const packageName = flags.packageName || oldPackage;
  if (!/^[A-Za-z0-9_-]+$/.test(binary || ""))
    throw new Error("A safe binary name is required (letters, digits, _ and -)");
  if (!/^(?:@[a-z0-9_.-]+\/)?[a-z0-9_.-]+$/.test(packageName || ""))
    throw new Error("A valid lowercase npm package name is required");
  const edits = new Map();
  const moves = [];
  const text = (file) => fs.readFileSync(file, "utf8");
  const stage = (file, content) => {
    file = owned(file);
    const original = text(file);
    if (original !== content) edits.set(file, { original, content, mode: fs.statSync(file).mode });
  };
  const json = (file, value) => stage(file, JSON.stringify(value, null, 2) + "\n");
  const replacePackage = (name) =>
    name === oldPackage
      ? packageName
      : name.startsWith(oldPackage + "-")
        ? packageName + name.slice(oldPackage.length)
        : name;
  const renameFile = (file) =>
    typeof file === "string"
      ? file.replace(
          new RegExp(`(^|/)${oldBinary.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}\\.`),
          `$1${binary}.`,
        )
      : file;
  const renamePaths = (value) => {
    if (typeof value === "string") return renameFile(value);
    if (Array.isArray(value)) return value.map(renamePaths);
    if (value && typeof value === "object")
      return Object.fromEntries(
        Object.entries(value).map(([key, child]) => [key, renamePaths(child)]),
      );
    return value;
  };
  const renameMetadata = (metadata) => {
    for (const field of ["main", "types", "module", "browser", "exports", "imports"])
      if (metadata[field] !== undefined) metadata[field] = renamePaths(metadata[field]);
    if (metadata.browser && typeof metadata.browser === "object")
      metadata.browser = Object.fromEntries(
        Object.entries(metadata.browser).map(([key, value]) => [renameFile(key), value]),
      );
    if (Array.isArray(metadata.files)) metadata.files = metadata.files.map(renameFile);
  };
  pkg.name = flags.name ?? pkg.name;
  renameMetadata(pkg);
  config.binaryName = binary;
  config.packageName = packageName;
  if (flags.description !== undefined) pkg.description = flags.description;
  if (flags.author !== undefined) pkg.author = flags.author;
  if (flags.repository !== undefined) {
    pkg.repository =
      pkg.repository && typeof pkg.repository === "object"
        ? { ...pkg.repository, url: flags.repository }
        : flags.repository;
  }
  if (configPath) json(configPath, config);
  else pkg.napi = config;
  if (pkg.optionalDependencies)
    pkg.optionalDependencies = Object.fromEntries(
      Object.entries(pkg.optionalDependencies).map(([name, version]) => [
        replacePackage(name),
        version,
      ]),
    );
  const npmRoot = path.resolve(cwd, flags.npmDir || "npm");
  if (fs.existsSync(npmRoot)) {
    owned(npmRoot);
    for (const entry of fs.readdirSync(npmRoot, { withFileTypes: true })) {
      if (!entry.isDirectory()) continue;
      const file = path.join(npmRoot, entry.name, "package.json");
      if (!fs.existsSync(file)) continue;
      const metadata = JSON.parse(text(owned(file)));
      if (metadata.name?.startsWith(oldPackage + "-")) {
        metadata.name = replacePackage(metadata.name);
        renameMetadata(metadata);
        json(file, metadata);
      }
    }
  }
  if (binary !== oldBinary || packageName !== oldPackage) {
    const escaped = oldBinary.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const moduleName = new RegExp(`(NODE_API_MODULE(?:_WITH_INIT)?\\(\\s*)"${escaped}"`, "g");
    const buildName = new RegExp(`(\\.name\\s*=\\s*)"${escaped}"`, "g");
    const walk = (directory) => {
      for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
        if (
          ["node_modules", ".git", ".zig-cache"].includes(entry.name) ||
          entry.name.startsWith(".tmp")
        )
          continue;
        const file = path.join(directory, entry.name);
        if (entry.isSymbolicLink()) continue;
        if (entry.isDirectory()) {
          walk(file);
          continue;
        }
        if (entry.name.endsWith(".zig"))
          stage(
            file,
            text(file)
              .replace(moduleName, `$1${JSON.stringify(binary)}`)
              .replace(buildName, `$1${JSON.stringify(binary)}`),
          );
        if (/\.(?:cjs|mjs|js|cts|ts)$/.test(entry.name)) {
          const source = text(file);
          const managed =
            source.includes("auto-generated by NAPI-RS") ||
            source.includes("This file was automatically generated by NAPI-RS") ||
            source.includes("__emnapiContext") ||
            (source.includes("const binaryName =") &&
              source.includes("NAPI_RS_NATIVE_LIBRARY_PATH"));
          if (managed)
            stage(
              file,
              source
                .replaceAll(oldBinary + ".", binary + ".")
                .replaceAll(oldPackage + "-", packageName + "-")
                .replaceAll(JSON.stringify(oldBinary), JSON.stringify(binary))
                .replaceAll(JSON.stringify(oldPackage), JSON.stringify(packageName)),
            );
        }
        if (binary === oldBinary || !entry.name.startsWith(oldBinary + ".")) continue;
        const suffix = entry.name.slice(oldBinary.length);
        if (
          !/^\.(?:(?:[cm]?js)|node|d\.[cm]?ts|(?:wasi|wasip1)(?:[-.].*)?\.(?:cjs|js|cts|ts)|(?:linux|darwin|win32|freebsd|android|wasm32)-.*\.(?:node|wasm))$/.test(
            suffix,
          )
        )
          continue;
        const destination = path.join(directory, binary + suffix);
        if (fs.existsSync(destination))
          throw new Error(`Rename destination already exists: ${destination}`);
        moves.push([file, destination]);
      }
    };
    walk(cwd);
  }
  const manifestPath = flags.manifestPath || "build.zig.zon";
  if (binary !== oldBinary && (flags.manifestPath || fs.existsSync(path.join(cwd, manifestPath)))) {
    const manifest = owned(manifestPath);
    if (!manifest.endsWith(".zig.zon"))
      throw new Error("--manifest-path for Zig rename must name a build.zig.zon manifest");
    const identifier = binary.replaceAll("-", "_");
    stage(
      manifest,
      text(manifest)
        .replace(/(\.name\s*=\s*)\.[A-Za-z_][A-Za-z0-9_]*/, `$1.${identifier}`)
        .replace(/(\.fingerprint\s*=\s*)0x[0-9a-f]+/i, (_match, prefix) => prefix + "0x0"),
    );
  }
  const workflowPath = path.join(cwd, ".github", "workflows", "CI.yml");
  if (binary !== oldBinary && fs.existsSync(workflowPath)) {
    stage(
      workflowPath,
      text(workflowPath).replace(
        /^(  APP_NAME:).*/m,
        (_match, prefix) => prefix + " " + JSON.stringify(binary),
      ),
    );
  }
  json(packagePath, pkg);
  if (flags.dryRun) {
    console.log(
      JSON.stringify(
        {
          writes: [...edits].map(([file, edit]) => ({ file, content: edit.content })),
          renames: moves,
        },
        null,
        2,
      ),
    );
    return;
  }
  const written = [];
  const moved = [];
  const temporary = [];
  try {
    for (const [file, edit] of edits) {
      const temp = file + `.zig-napi-${process.pid}.tmp`;
      fs.writeFileSync(temp, edit.content, { flag: "wx", mode: edit.mode });
      temporary.push(temp);
      fs.renameSync(temp, file);
      written.push(file);
    }
    for (const [from, to] of moves) {
      fs.renameSync(from, to);
      moved.push([from, to]);
    }
  } catch (error) {
    for (const [from, to] of moved.reverse()) fs.renameSync(to, from);
    for (const file of written.reverse())
      fs.writeFileSync(file, edits.get(file).original, { mode: edits.get(file).mode });
    throw error;
  } finally {
    for (const temp of temporary) if (fs.existsSync(temp)) fs.unlinkSync(temp);
  }
};
