const std = @import("std");

var expected_external = std.atomic.Value(usize).init(0);
var expected_class = std.atomic.Value(usize).init(0);
var seen_external = std.atomic.Value(usize).init(0);
var seen_class = std.atomic.Value(usize).init(0);
var printed = std.atomic.Value(bool).init(false);

pub fn begin_finalizer_state_check(external_count: usize, class_count: usize) void {
    expected_external.store(external_count, .monotonic);
    expected_class.store(class_count, .monotonic);
    seen_external.store(0, .monotonic);
    seen_class.store(0, .monotonic);
    printed.store(false, .monotonic);
}

pub fn onExternalFinalized() void {
    _ = seen_external.fetchAdd(1, .monotonic);
    maybePrintResult();
}

pub fn onClassFinalized() void {
    _ = seen_class.fetchAdd(1, .monotonic);
    maybePrintResult();
}

fn maybePrintResult() void {
    const external_count = seen_external.load(.monotonic);
    const class_count = seen_class.load(.monotonic);
    const external_expected = expected_external.load(.monotonic);
    const class_expected = expected_class.load(.monotonic);

    if (external_expected == 0 and class_expected == 0) {
        return;
    }
    if (external_count < external_expected or class_count < class_expected) {
        return;
    }
    if (printed.swap(true, .monotonic)) {
        return;
    }

    std.debug.print("__ZIG_NAPI_FINALIZER_RESULT__ status=ok external={d} class={d}\n", .{ external_count, class_count });
}
