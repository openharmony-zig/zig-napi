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

export function assertArrayEqual(actual: Array<ESObject>, expected: Array<ESObject>, message: string) {
  assertEqual(actual.length, expected.length, `${message}.length`);
  for (let i = 0; i < expected.length; i++) {
    assertEqual(actual[i], expected[i], `${message}[${i}]`);
  }
}

export function assertThrows(run: () => void, message: string) {
  try {
    run();
  } catch (_) {
    return;
  }
  fail(`${message}: expected throw`);
}

export async function assertRejects(promise: ESObject, expected: string, message: string) {
  try {
    await promise;
  } catch (err) {
    const text = String(err && (err.message || err));
    if (text.indexOf(expected) >= 0) {
      return;
    }
    fail(`${message}: expected rejection containing ${expected}, actual=${text}`);
  }
  fail(`${message}: expected rejection`);
}
