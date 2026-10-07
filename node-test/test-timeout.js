// QEMU TCG guests retain every assertion and workload, with a larger wall-clock
// budget for process startup and native producers. Native runs default to 1.
const multiplier = Number(process.env.ZIG_NAPI_TEST_TIMEOUT_MULTIPLIER || 1);
if (!Number.isInteger(multiplier) || multiplier < 1 || multiplier > 10) {
  throw new Error("ZIG_NAPI_TEST_TIMEOUT_MULTIPLIER must be an integer from 1 to 10");
}
module.exports = (milliseconds) => milliseconds * multiplier;
