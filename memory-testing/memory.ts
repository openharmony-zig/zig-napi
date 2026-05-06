import { exerciseAsyncWrappers, exerciseThreadSafeFunctionWrapper } from "./async";
import { exerciseBinaryWrappers } from "./binary";
import { exerciseFinalizerWrappers } from "./finalizers";
import { runMemorySuite, withLeakTracking } from "./native";
import { exerciseSyncWrappers } from "./sync";

const RESULT_PREFIX = "__ZIG_NAPI_MEMORY_RESULT__";

runMemorySuite(RESULT_PREFIX, async (native) => {
  await withLeakTracking(native, "sync wrappers", () => {
    exerciseSyncWrappers(native);
    exerciseBinaryWrappers(native);
  });
  exerciseFinalizerWrappers(native);
  await withLeakTracking(native, "async wrappers", () => exerciseAsyncWrappers(native));
  await exerciseThreadSafeFunctionWrapper(native);
});
