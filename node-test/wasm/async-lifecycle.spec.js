// WASI async lifecycle: the pre-teardown barrier handshake and the event queue,
// on both real flavors of the artifact the build produces.
//
// Every scenario runs in a child process (`./async-child.cjs`) with a
// timeout enforced *here*: a stall inside wasm blocks the event loop that an
// in-process watchdog would need, so the parent is the only thing that can
// still tell "slow" from "wedged". The child prints one `RESULT {...}` line and
// is expected to exit on its own (no `process.exit` masking a stuck worker).
const test = require("ava");
const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

const nodeTestDir = path.join(__dirname, "..");
const childPath = path.join(__dirname, "async-child.cjs");

const forceWasi =
  process.env.NAPI_RS_FORCE_WASI === "true" || process.env.NAPI_RS_FORCE_WASI === "error";

/// The two flavors the build produces side by side: the threaded one imports a
/// shared memory, the threadless one does not.
const flavors = [
  { file: "async_tasks.wasm32-wasi.wasm", threaded: true },
  { file: "async_tasks.wasm32-wasip1.wasm", threaded: false },
]
  .map((flavor) => ({ ...flavor, path: path.join(nodeTestDir, flavor.file) }))
  .filter((flavor) => fs.existsSync(flavor.path));

// A run that never built a WASI artifact (the native matrix) has nothing to
// test here; a run that asks for WASI must fail when the artifact is missing.
const wasiTest = !forceWasi && flavors.length === 0 ? test.skip : test;

function runScenario(scenario, flavor, timeoutMs = 60000, env = {}) {
  const started = Date.now();
  const result = spawnSync(
    process.execPath,
    [childPath, scenario, flavor.path, flavor.threaded ? "threaded" : "threadless"],
    {
      cwd: nodeTestDir,
      encoding: "utf8",
      env: { ...process.env, ...env },
      timeout: timeoutMs,
    },
  );
  const elapsed = Date.now() - started;
  const lines = String(result.stdout || "").split("\n");
  const resultLine = lines.filter((line) => line.startsWith("RESULT ")).pop();
  let payload;
  if (resultLine) {
    try {
      payload = JSON.parse(resultLine.slice("RESULT ".length));
    } catch (error) {
      payload = { parseError: String(error) };
    }
  }
  return {
    payload,
    elapsed,
    signal: result.signal,
    stderr: String(result.stderr || ""),
    status: result.status,
    timedOut: result.error && result.error.code === "ETIMEDOUT",
  };
}

/// Run one scenario against every built flavor and hand the parsed result to
/// `assert`. A timeout or a non-zero exit fails with the child's own output, so
/// a wedge is reported as a wedge instead of a missing assertion.
function forEachFlavor(t, scenario, assert, options) {
  const observed = [];
  for (const flavor of flavors) {
    const outcome = runScenario(
      scenario,
      flavor,
      options && options.timeoutMs,
      options && options.env,
    );
    const label = `${scenario} (${flavor.threaded ? "threaded" : "threadless"})`;
    if (outcome.timedOut) {
      t.fail(
        `${label}: no result within the parent-enforced timeout; child output: ${outcome.stderr.trim().slice(-400)}`,
      );
      continue;
    }
    if (outcome.status !== 0 || !outcome.payload) {
      t.fail(
        `${label}: exited with ${outcome.status}${outcome.signal ? ` (${outcome.signal})` : ""}: ${outcome.stderr.trim().slice(-600)}`,
      );
      continue;
    }
    observed.push({ flavor, outcome });
    assert(t, flavor, outcome.payload);
  }
  t.true(observed.length > 0, "at least one flavor must produce a result");
}

wasiTest("the pre-teardown barrier exports exist on both flavors", (t) => {
  forEachFlavor(t, "barrier", (assertT, flavor, result) => {
    assertT.is(
      result.exports,
      "function",
      `${flavor.file}: napi_prepare_wasm_env_cleanup must be exported`,
    );
    assertT.is(result.before, 0, `${flavor.file}: an idle environment has nothing queued`);
    // Called twice: the loader may retry a disposal.
    assertT.is(result.pending, 0, `${flavor.file}: the barrier stays idempotent`);
  });
});

wasiTest("the barrier settles a task it cannot cancel in time", (t) => {
  forEachFlavor(t, "cancellation", (assertT, flavor, result) => {
    assertT.is(result.settled.state, "rejected", `${flavor.file}: the escaped promise must settle`);
    assertT.is(result.settled.code, "AbortError", `${flavor.file}: with the cancellation error`);
    assertT.is(result.pendingRightAfter, 0, `${flavor.file}: a direct settlement is not queued`);
    assertT.not(result.drained, -1, `${flavor.file}: nothing stays queued behind it`);
  });
});

wasiTest("work submitted after the barrier is refused, not started", (t) => {
  forEachFlavor(t, "refusal", (assertT, flavor, result) => {
    assertT.is(result.refused.state, "rejected", `${flavor.file}: the promise must reject`);
    assertT.is(result.refused.code, "Cancelled", `${flavor.file}: with the shutdown error`);
    assertT.is(result.delivered, 0, `${flavor.file}: no event may be produced`);
    assertT.is(result.pending, 0, `${flavor.file}: refused work queues no settlement`);
  });
});

wasiTest("a finished task whose completion is not published yet still settles", (t) => {
  forEachFlavor(t, "finished_unpublished", (assertT, flavor, result) => {
    if (result.skipped) {
      // Only a worker can get ahead of the host's completion callback; the
      // threadless host runs the task body itself.
      assertT.is(flavor.threaded, false, `${flavor.file}: only the threadless flavor may skip`);
      return;
    }
    assertT.is(result.primed, 2, `${flavor.file}: the pool must be warm`);
    assertT.is(result.pendingAtBarrier, 0, `${flavor.file}: nothing was queued yet`);
    assertT.is(
      result.settled.state,
      "resolved",
      `${flavor.file}: the task's own result must settle it`,
    );
    assertT.is(result.settled.value, 3, `${flavor.file}: with the value it produced`);
    assertT.not(result.drained, -1, `${flavor.file}: the queue ends empty`);
  });
});

wasiTest("events past the queue limit stay ordered and never wedge the host", (t) => {
  forEachFlavor(t, "burst", (assertT, flavor, result) => {
    assertT.is(result.delivered, result.total, `${flavor.file}: no event may be lost`);
    assertT.is(result.firstOutOfOrder, -1, `${flavor.file}: events must keep the producer's order`);
    assertT.is(result.value, result.total, `${flavor.file}: the task must resolve`);
    assertT.is(result.pending, 0, `${flavor.file}: every settlement was delivered`);
    if (flavor.threaded) {
      // The bounded queue is real on the worker flavor, and the producer parks
      // on it instead of growing memory.
      assertT.is(
        result.highWater,
        result.limit,
        `${flavor.file}: the producer must park on the bound`,
      );
      assertT.is(result.inline, false, `${flavor.file}: worker events go through the queue`);
    } else {
      // Nothing could drain a queue the producer waits on when the producer *is*
      // the host thread, so events are delivered inline there.
      assertT.is(result.inline, true, `${flavor.file}: a threadless producer must not queue`);
      assertT.is(result.highWater, 0, `${flavor.file}: nothing is in flight`);
    }
  });
});

wasiTest("concurrent threaded tasks keep their results independent", (t) => {
  forEachFlavor(t, "concurrent_tasks", (assertT, flavor, result) => {
    assertT.true(result.matches, `${flavor.file}: every task must return its own value`);
  });
});

wasiTest("a throwing listener rejects with its own value", (t) => {
  forEachFlavor(t, "listener_throw", (assertT, flavor, result) => {
    assertT.true(result.identity, `${flavor.file}: the rejection reason must be the thrown value`);
  });
});

wasiTest("cancellation reaches the producer without a timer, on both flavors", (t) => {
  forEachFlavor(t, "abort_from_callback", (assertT, flavor, result) => {
    assertT.is(result.pre.state, "rejected", `${flavor.file}: a pre-aborted task must reject`);
    assertT.is(result.pre.code, "AbortError", `${flavor.file}: with AbortError`);
    for (const [index, settled] of result.settled.entries()) {
      assertT.is(settled.state, "rejected", `${flavor.file}: task ${index} must reject`);
      assertT.is(
        settled.code,
        "AbortError",
        `${flavor.file}: task ${index} must reject with AbortError`,
      );
    }
    // The producer stopped at its next checkpoint instead of finishing: a
    // threadless host observes the abort on the very event that raised it, a
    // worker flavor a few hundred events later.
    assertT.true(result.delivered >= 1, `${flavor.file}: at least one event must be produced`);
    assertT.true(
      result.delivered < result.total,
      `${flavor.file}: the producer must stop early (${result.delivered} of ${result.total})`,
    );
  });
});

wasiTest("the barrier never settles ahead of progress the task already queued", (t) => {
  forEachFlavor(t, "throw_after_finish", (assertT, flavor, result) => {
    if (result.skipped) {
      // Threadless events are delivered inline, so the barrier always meets a
      // running task there and the cancellation is the outcome (asserted by the
      // cancellation case).
      assertT.is(flavor.threaded, false, `${flavor.file}: only the threadless flavor may skip`);
      return;
    }
    // The barrier found the task finished with progress still queued: it has to
    // queue the settlement behind that progress.
    assertT.true(
      result.barrierPending >= 1,
      `${flavor.file}: the deferred settlement must be visible to the loader`,
    );
    assertT.is(
      result.seen.length,
      result.total,
      `${flavor.file}: every queued event must still be delivered`,
    );
    assertT.deepEqual(result.seen, [0, 1, 2], `${flavor.file}: in the producer's order`);
    assertT.true(
      result.identity,
      `${flavor.file}: the queued listener's own throw must be the rejection reason`,
    );
    assertT.not(result.drained, -1, `${flavor.file}: the queue ends empty`);
  });
});

// Same deferral, with a primitive thrown value: the reason must be that value
// itself, not an error re-created from its text.
wasiTest("the deferred settlement keeps a primitive thrown identity", (t) => {
  forEachFlavor(
    t,
    "throw_after_finish",
    (assertT, flavor, result) => {
      if (result.skipped) {
        assertT.is(flavor.threaded, false, `${flavor.file}: only the threadless flavor may skip`);
        return;
      }
      assertT.is(
        result.reasonType,
        "string",
        `${flavor.file}: the primitive must be the rejection reason`,
      );
      assertT.true(result.identity, `${flavor.file}: identity, not a copy of the text`);
      assertT.is(result.seen.length, result.total, `${flavor.file}: every queued event still runs`);
    },
    { env: { WASM_ASYNC_THROWN: "primitive" } },
  );
});

// Concurrent tasks that each produce progress events are the one case the
// current emnapi 2 composition does not survive on the worker flavor: the
// The JavaScript thread-safe-function plugin allocates its queue nodes with the
// module's exported `malloc` from *every* worker realm. That allocator is
// serialized now (`src/sys/emnapi_alloc.zig`, CONTRACT-abi.md), so concurrent
// producers must stay ordered on the worker flavor as well: this test used to
// run on the threadless flavor only and let the other flavor pass silently,
// which hid the shared-heap corruption entirely.
wasiTest("concurrent progress is ordered on both flavors", (t) => {
  t.deepEqual(
    flavors.map((flavor) => flavor.file).sort(),
    ["async_tasks.wasm32-wasi.wasm", "async_tasks.wasm32-wasip1.wasm"],
    "both flavors must be built; a missing artifact is a failure, not a skip",
  );
  for (const flavor of flavors) {
    // Repeated: heap corruption from concurrent producers is timing dependent,
    // so one clean round is not evidence.
    for (let round = 1; round <= 3; round += 1) {
      const label = `${flavor.file} round ${round}`;
      const outcome = runScenario("concurrent_progress", flavor, 60000);
      t.is(
        outcome.status,
        0,
        `${label}: concurrent progress must not crash: ${outcome.stderr.trim().slice(-400)}`,
      );
      t.true(outcome.payload.ordered, `${label}: every task must deliver its events in order`);
      t.is(outcome.payload.pending, 0, `${label}: every settlement must be delivered`);
    }
  }
});
