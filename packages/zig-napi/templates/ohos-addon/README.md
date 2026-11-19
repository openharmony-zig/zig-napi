# `__PACKAGE_NAME__`

Build the OpenHarmony native addon with the patched Zig 0.17.0 toolchain. Set `OHOS_NDK_HOME` to the SDK directory containing `native/sysroot`.

```sh
zig build --prefix package/libs
```

This builds `lib__ADDON_NAME__.so` for arm64-v8a, armeabi-v7a and x86_64 and regenerates `package/types/Index.d.ts`. To build a single ABI, add `-Dtarget=aarch64-linux-ohos`, `-Dtarget=arm-linux-ohoseabi` or `-Dtarget=x86_64-linux-ohos`.

Open this project in DevEco Studio and build the `addon` HAR module, or run the DevEco command-line tools from the project root.

```sh
ohpm install
hvigorw --mode module -p module=addon@default assembleHar
```

Install the resulting HAR in your application's entry module, then import the Zig function in ArkTS.

```ts
import { add } from "__PACKAGE_NAME__";

const answer: number = add(20, 22);
```
