# zig-addon

This project can help us to build a native module library for OpenHarmony/HarmonyNext with zig-lang.

> Note: This project is still in the early stage of development and is not ready for use. You can use it as a toy.


```zig
const napi = @import("napi");

fn add(callback_info: napi.CallbackInfo) napi.Value {
    const a = callback_info.Get(0).As(napi.Number);
    const b = callback_info.Get(1).As(napi.Number);
    const result = a.FloatValue() + b.FloatValue();
    const result_number = napi.Number.New(callback_info.Env(), result);
    return result_number.ToValue();
}

fn init(_: napi.Env, exports: napi.Object) napi.Object {
    exports.Set("add", add);
    return exports;
}

comptime {
    napi.NODE_API_MODULE("hello", init);
}
```


## Goal

Our goal is to provide a zig version similar to the `node-addon-api`.

- [x] Out of box building system.
- [ ] Macro for napi.

## Example

We provide a simple example to help you get started in `examples/add`.

Just run the following command to build the example:

```bash
zig build
```

And you can get `libadd.so` in `zig-out/dist`.


## LICENSE

[MIT](./LICENSE)