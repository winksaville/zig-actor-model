const std = @import("std");
const assert = std.debug.assert;
const warn = std.debug.warn;
const mem = std.mem;
const math = std.math;
const Queue = std.atomic.Queue;

const builtin = @import("builtin");
const AtomicOrder = builtin.AtomicOrder;
const AtomicRmwOp = builtin.AtomicRmwOp;

const linux = switch(builtin.os) {
    builtin.Os.linux => std.os.linux,
    else => @compileError("Only builtin.os.linux is supported"),
};

pub use switch(builtin.arch) {
    builtin.Arch.x86_64 => @import("../zig/std/os/linux/x86_64.zig"),
    else => @compileError("unsupported arch"),
};



pub fn futex_wait(pVal: *u32, expected_value: u32) void {
    //warn("futex_wait: {*}\n", pVal);
    _ = syscall4(SYS_futex, @ptrToInt(pVal), linux.FUTEX_WAIT, expected_value, 0);
}

pub fn futex_wake(pVal: *u32, num_threads_to_wake: u32) void {
    //warn("futex_wake: {*}\n", pVal);
    _ = syscall4(SYS_futex, @ptrToInt(pVal), linux.FUTEX_WAKE, num_threads_to_wake, 0);
}


const ThreadContext = struct {
    const Self = this;

    name_len: usize,
    name: [32]u8,
    counter: u128,

    pub fn init(pSelf: *Self, name: [] const u8) void {
        // Set name_len and then copy with truncation
        pSelf.name_len = math.min(name.len, pSelf.name.len);
        mem.copy(u8, pSelf.name[0..pSelf.name_len], name[0..pSelf.name_len]);

        pSelf.counter = 0;
    }
};

var gProducer_context: ThreadContext = undefined;
var gConsumer_context: ThreadContext = undefined;

var produce: u32 = 0;
var gCounter: u128 = 0;

fn producer(pContext: *ThreadContext) void {
    while (pContext.counter < 1000000) {
        // Wait for consumer to request production
        while (@atomicLoad(@typeOf(produce), &produce, AtomicOrder.SeqCst) == 0) {
            futex_wait(&produce, 0);
        }

        // Produce
        gCounter += 1;
        pContext.counter += 1;

        // Tell consumer we produced with "store 0"
        _ = @atomicRmw(@typeOf(produce), &produce, AtomicRmwOp.Xchg, 0, AtomicOrder.SeqCst);
        futex_wake(&produce, 1);
    }
}

fn consumer(pContext: *ThreadContext) void {
    while (pContext.counter < 1000000) {
        // Tell producer to produce with "store 1"
        _ = @atomicRmw(@typeOf(produce), &produce, AtomicRmwOp.Xchg, 1, AtomicOrder.SeqCst);
        futex_wake(&produce, 1);

        // Wait until something is produced by seeing a 0
        while (@atomicLoad(@typeOf(produce), &produce, AtomicOrder.SeqCst) == 1) {
            futex_wait(&produce, 1);
        }

        // Consume
        gCounter += 1;
        pContext.counter += 1;
    }
}

test "Futex" {
    warn("\ntest Futex:+ gCounter={}\n", gCounter);
    defer warn("test Futex:- gCounter={}\n", gCounter);

    gProducer_context.init("producer");
    gConsumer_context.init("consumer");
    var producerThread = try std.os.spawnThread(&gProducer_context, producer);
    var consumerThread = try std.os.spawnThread(&gConsumer_context, consumer);

    producerThread.wait();
    consumerThread.wait();
    warn("test Futex: gCounter={}\n", gCounter);

    assert(gCounter == 2000000);
}
