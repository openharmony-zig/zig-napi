const fs = require("node:fs");
const path = require("node:path");

// Ship the exact library revision used to publish the CLI. Installed packages
// cannot depend on the monorepo being two directories above their executable.
const packageDir = path.resolve(__dirname, "..");
const source = path.resolve(packageDir, "..", "..");
const destination = path.join(packageDir, "zig");
if (fs.existsSync(path.join(source, "src", "napi.zig"))) {
  fs.mkdirSync(destination, { recursive: true });
  // This directory is generated only; don't retain files deleted upstream
  // when publishing repeatedly from the same checkout.
  fs.rmSync(path.join(destination, "src"), { recursive: true, force: true });
  fs.cpSync(path.join(source, "src"), path.join(destination, "src"), { recursive: true });
  for (const name of ["build.zig", "build.zig.zon", "LICENSE", "README.md"]) {
    fs.copyFileSync(path.join(source, name), path.join(destination, name));
  }
} else if (!fs.existsSync(path.join(destination, "src", "napi.zig"))) {
  throw new Error("Cannot pack the CLI without its zig-napi library sources");
}
