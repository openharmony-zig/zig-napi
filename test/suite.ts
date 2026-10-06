import { testAsync } from "./async.spec";
import { testBinary } from "./binary.spec";
import { testErrorsAndThreadSafeFunction } from "./errors-tsfn.spec";
import { testExternal } from "./external.spec";
import { testFunctionsAndClasses } from "./functions-classes.spec";
import { testObjectsAndArrays } from "./objects-arrays.spec";
import { testPrimitives } from "./primitives.spec";
import { testUnionsAndEnums } from "./unions-enums.spec";
import {
  testParity,
  testParityProtocols,
  testParityLifetimes,
  testParityStreams,
} from "./parity.spec";

export async function runBasicSuite(
  native: ESObject,
  fixtureRoot: string,
  report: (name: string) => void,
) {
  testPrimitives(native);
  report("primitives");
  testObjectsAndArrays(native);
  report("objects-arrays");
  testBinary(native);
  report("binary");
  testFunctionsAndClasses(native);
  report("functions-classes");
  testExternal(native);
  report("external");
  await testAsync(native, fixtureRoot);
  report("async");
  testUnionsAndEnums(native);
  report("unions-enums");
  await testErrorsAndThreadSafeFunction(native);
  report("errors-tsfn");
  await testParity(native);
  report("parity");
  await testParityProtocols(native);
  report("parity-protocols");
  await testParityLifetimes(native);
  report("parity-lifetimes");
  await testParityStreams(native);
  report("parity-streams");
}
