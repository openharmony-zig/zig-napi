export function fail(message: string): never {
  throw new Error(message);
}

export function assert(condition: boolean, message: string) {
  if (!condition) {
    fail(message);
  }
}

export function assertEqual(actual: ESObject, expected: ESObject, message: string) {
  if (actual !== expected) {
    fail(`${message}: expected=${String(expected)} actual=${String(actual)}`);
  }
}

export function assertNullish(actual: ESObject, message: string) {
  if (actual !== null && actual !== undefined) {
    fail(`${message}: expected nullish actual=${String(actual)}`);
  }
}

export function assertApproxEqual(actual: number, expected: number, message: string, epsilon: number = 0.00001) {
  if (Math.abs(actual - expected) > epsilon) {
    fail(`${message}: expected=${String(expected)} actual=${String(actual)}`);
  }
}

export function assertArrayEqual(actual: Array<ESObject>, expected: Array<ESObject>, message: string) {
  assertEqual(actual.length, expected.length, `${message}.length`);
  for (let i = 0; i < expected.length; i++) {
    assertEqual(actual[i], expected[i], `${message}[${i}]`);
  }
}

export function assertIncludes(actual: string, expected: string, message: string) {
  if (actual.indexOf(expected) < 0) {
    fail(`${message}: expected to include=${expected} actual=${actual}`);
  }
}

export function assertThrows(fn: () => void, expectedMessage: string, message: string) {
  let threw = false;
  try {
    fn();
  } catch (err) {
    threw = true;
    const actual = String(err && (err.message || err));
    assertIncludes(actual, expectedMessage, message);
  }
  assert(threw, `${message}: expected throw`);
}

export async function assertRejects(promise: Promise<any>, expectedMessage: string, message: string) {
  let rejected = false;
  try {
    await promise;
  } catch (err) {
    rejected = true;
    const actual = String(err && (err.message || err));
    assertIncludes(actual, expectedMessage, message);
  }
  assert(rejected, `${message}: expected rejection`);
}
