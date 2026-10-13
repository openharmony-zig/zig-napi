const test = require("ava");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");
const root = path.resolve(__dirname, "../../..");
const isWasi = ["true", "error"].includes(process.env.NAPI_RS_FORCE_WASI);
const nativeTest = isWasi ? test.skip : test;

function withFixture(source, version, action) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "zig-napi-runtime-"));
  try {
    const fixture = path.join(directory, "fixture.zig");
    const options = path.join(directory, "options.zig");
    fs.writeFileSync(fixture, source);
    fs.writeFileSync(options, `pub const node_addon = true; pub const napi_tsgen = true; pub const napi_version: i32 = ${version}; pub const napi_experimental = false;`);
    const modules = ["--dep", "napi-sys", "--dep", "build_options", `-Mnapi=${path.join(root, "src/napi.zig")}`, "--dep", "build_options", `-Mnapi-sys=${path.join(root, "src/sys/api.zig")}`, `-Mbuild_options=${options}`];
    action({ directory, fixture, modules });
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
}

for (const payload of ["*Self", "*const Self", "!*Self", "!*const Self", "napi.Result(*Self)", "napi.Result(*const Self)"]) {
  nativeTest(`class factories reject ${payload} returns`, (t) => {
    withFixture(`const napi = @import("napi");
const Model = struct {
    const Self = @This();
    pub fn make() ${payload} { return undefined; }
};
export fn probe() void { _ = napi.ClassWithoutInit(Model).to_napi_value(napi.Env.from_raw(null)) catch {}; }
`, 8, ({ fixture, modules }) => {
      const result = spawnSync("zig", ["build-obj", "-fno-emit-bin", "--dep", "napi", `-Mroot=${fixture}`, ...modules], { cwd: root, encoding: "utf8", timeout: 20000 });
      t.not(result.status, 0, result.stderr);
      t.regex(result.stderr, /factory must return.*by value/i);
    });
  });
}

for (const type of ["u64", "i64"]) {
  nativeTest(`${type} generic conversion requires Node-API v6`, (t) => {
    withFixture(`const napi = @import("napi");
export fn probe() void { _ = napi.NapiValue.from_raw(null, null).As(${type}) catch {}; }
`, 5, ({ fixture, modules }) => {
      const result = spawnSync("zig", ["build-obj", "-fno-emit-bin", "--dep", "napi", `-Mroot=${fixture}`, ...modules], { cwd: root, encoding: "utf8", timeout: 20000 });
      t.not(result.status, 0, result.stderr);
      t.regex(result.stderr, /Node-API Version Mismatch/);
    });
  });
}

nativeTest("declarations map wide integers and BigInt recursively", (t) => {
  t.timeout(60000);
  withFixture(`const napi = @import("napi");
pub const Record = struct { signed: i64, unsigned: u64, huge: i128, wrapped: napi.BigInt, optional: ?u64, array: [2]i64, size: usize, c: c_long, other: u63 };
pub fn echo(value: Record) Record { return value; }
pub fn promise() napi.Async(u64, .single) { return undefined; }
fn source(value: i64, values: []u64, huge: u128, wrapped: napi.BigInt) ?i64 { _ = .{value, values, huge, wrapped}; return null; }
fn init(env: napi.Env, exports: napi.Object) !?napi.Object {
    _ = env;
    try exports.Set("source", source);
    return null;
}
comptime { napi.NODE_API_MODULE_WITH_INIT("fixture", @This(), init); }
`, 8, ({ directory, fixture, modules }) => {
    const output = path.join(directory, "index.d.ts");
    const result = spawnSync("zig", ["run", "--dep", "napi", "--dep", "addon_root", `-Mroot=${path.join(root, "src/build/napi-tsgen.zig")}`, "--dep", "napi", `-Maddon_root=${fixture}`, ...modules, "--", output, fixture], { cwd: root, encoding: "utf8", timeout: 50000 });
    t.is(result.status, 0, result.stderr);
    const declaration = fs.readFileSync(output, "utf8");
    for (const field of ["signed", "unsigned", "huge", "wrapped"]) t.regex(declaration, new RegExp(`${field}: bigint`));
    t.regex(declaration, /optional\?: bigint/);
    t.regex(declaration, /array: Array<bigint>/);
    for (const field of ["size", "c", "other"]) t.regex(declaration, new RegExp(`${field}: number`));
    t.regex(declaration, /promise\(\): Promise<bigint>/);
    t.regex(declaration, /source\(value: bigint, values: Array<bigint>, huge: bigint, wrapped: bigint\): bigint \| undefined \| null/);
    t.notRegex(declaration, /interface BigInt/);
  });
});
