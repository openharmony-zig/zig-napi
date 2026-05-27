import { testAsync } from "./async.spec";
import { testBinary } from "./binary.spec";
import { testErrorsAndThreadSafeFunction } from "./errors-tsfn.spec";
import { testExternal } from "./external.spec";
import { testFunctionsAndClasses } from "./functions-classes.spec";
import { testObjectsAndArrays } from "./objects-arrays.spec";
import { testPrimitives } from "./primitives.spec";
import { testUnionsAndEnums } from "./unions-enums.spec";
import { runSuite } from "./native";

runSuite("__ZIG_NAPI_TEST_RESULT__", async (native) => {
  testPrimitives(native);
  testObjectsAndArrays(native);
  testBinary(native);
  testFunctionsAndClasses(native);
  testExternal(native);
  await testAsync(native);
  testUnionsAndEnums(native);
  await testErrorsAndThreadSafeFunction(native);
});
