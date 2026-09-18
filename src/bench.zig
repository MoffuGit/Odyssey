//Source https://github.com/tigerbeetle/tigerbeetle/tree/main
//License: [TIGERBEETLE]

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const Duration = Io.Duration;
const Timestamp = Io.Timestamp;

const log = std.log.scoped(.bench);

pub const mode: enum { smoke, benchmark } =
    // See build.zig for how this is ultimately determined.
    if (@import("test_options").benchmark) .benchmark else .smoke;

const seed_benchmark: u64 = 42;

test "benchmark: API tutorial" { // `benchmark:` in the name is important!
    const io = std.Io.Threaded.global_single_threaded.io();
    var bench: Bench = .init();
    defer bench.deinit();

    // Parameters are named, and have two default values.
    // The small value is used in tests, to prevent bitrot.
    // The large value is the canonical when running benchmark "for real".
    // You can pass custom values via env variables:
    //    $ a=92 ./zig/zig build test -- "benchmark: tutorial"
    const a = parameter("a", 1, 1_000);
    const b = parameter("b", 2, 2_000);

    bench.start(io);
    const c = a + b;
    const elapsed = bench.stop(io);

    // Always print a "hash" of the run:
    // - to prevent compiler from optimizing the code away,
    // - to prevent YOU from "optimizing" the code by changing semantics.
    report("hash: {}", .{c});
    // Print the time, and any other metrics you find important.
    report("elapsed: {}", .{elapsed});

    // NB: print as little as possible, because humans read slowly.
    // It's the job of benchmark author to optimize for conciseness.

    // You can compile individual benchmark  via
    //   ./zig/zig build test:unit:build -- "benchmark: binary search"
    // and use the resulting binary with perf/hyperfine/poop.
}

pub const Bench = @This();

seed: u64,
timestamp: ?Timestamp,

pub fn init() Bench {
    return .{
        // Benchmarks require a fixed seed for reproducibility; smoke mode uses a random seed.
        .seed = if (mode == .benchmark) seed_benchmark else std.testing.random_seed,
        .timestamp = null,
    };
}

pub fn deinit(bench: *Bench) void {
    assert(bench.timestamp == null);
    bench.* = undefined;
}

pub fn parameter(
    comptime name: []const u8,
    value_smoke: u64,
    value_benchmark: u64,
) u64 {
    assert(value_smoke < value_benchmark);
    const value = switch (mode) {
        .smoke => value_smoke,
        .benchmark => value_benchmark,
    };
    report("{s}={}", .{ name, value });
    return value;
}

pub fn start(bench: *Bench, io: Io) void {
    assert(bench.timestamp == null);
    defer assert(bench.timestamp != null);

    bench.timestamp = Timestamp.now(io, .real);
}

pub fn stop(bench: *Bench, io: Io) Duration {
    assert(bench.timestamp != null);
    defer assert(bench.timestamp == null);

    const instant_stop = Timestamp.now(io, .real);
    const elapsed = bench.timestamp.?.durationTo(instant_stop);
    bench.timestamp = null;
    return elapsed;
}

pub fn min(durations: []Duration) Duration {
    assert(durations.len >= 8);
    std.sort.block(Duration, durations, {}, asc);
    return durations[0];
}

pub fn max(durations: []Duration) Duration {
    assert(durations.len >= 8);
    std.sort.block(Duration, durations, {}, asc);
    return durations[durations.len - 1];
}

pub fn mean(durations: []Duration) Duration {
    assert(durations.len >= 8);
    var acc: i96 = 0;
    for (durations) |duration| {
        acc += duration.nanoseconds;
    }

    return .fromNanoseconds(@divTrunc(acc, durations.len));
}

fn asc(_: void, a: Duration, b: Duration) bool {
    return a.nanoseconds < b.nanoseconds;
}

pub fn report(comptime fmt: []const u8, args: anytype) void {
    switch (mode) {
        .smoke => {},
        .benchmark => log.info(fmt, args),
    }
}
