const std = @import("std");
const assert = std.debug.assert;
const warn = std.debug.warn;
const mem = std.mem;
const math = std.math;
const Queue = std.atomic.Queue;
const Timer = std.os.time.Timer;

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

    mode: bool,
    counter: u128,

    pub fn init(pSelf: *Self, mode: bool) void {
        pSelf.mode = mode;
        pSelf.counter = 0;
    }
};

var gProducer_context: ThreadContext = undefined;
var gConsumer_context: ThreadContext = undefined;

const naive = true;
const consumeSignal = 0;
const produceSignal = 1;
var produce: u32 = consumeSignal;
var gCounter: u64 = 0;
var gProducerWaitCount: u64 = 0;
var gConsumerWaitCount: u64 = 0;
var gProducerWakeCount: u64 = 0;
var gConsumerWakeCount: u64 = 0;

const max_counter = 10000000;
const stallCountWait: u32 = 10000;
const stallCountWake: u32 = 2000;

fn stallWhileNotDesiredVal(stallCount: u64, pValue: *u32, desiredValue: u32) u32 {
    var count = stallCount;
    var val = @atomicLoad(u32, pValue, AtomicOrder.SeqCst);
    while ((val != desiredValue) and (count > 0)) {
        val = @atomicLoad(u32, pValue, AtomicOrder.SeqCst);
        count -= 1;
    }
    return val;
}

fn stallWhileDesiredVal(stallCount: u64, pValue: *u32, desiredValue: u32) u32 {
    var count = stallCount;
    var val = @atomicLoad(u32, pValue, AtomicOrder.SeqCst);
    while ((val == desiredValue) and (count > 0)) {
        val = @atomicLoad(u32, pValue, AtomicOrder.SeqCst);
        count -= 1;
    }
    return val;
}

fn producer(pContext: *ThreadContext) void {
    if (pContext.mode == naive) {
        while (pContext.counter < max_counter) {
            // Wait for the produce to be the produceSignal
            while (@atomicLoad(@typeOf(produce), &produce, AtomicOrder.SeqCst) == consumeSignal) {
                gProducerWaitCount += 1;
                futex_wait(&produce, consumeSignal);
            }

            // Produce
            gCounter += 1;
            pContext.counter += 1;

            // Tell consumer to consume and then wake consumer up
            _ = @atomicRmw(@typeOf(produce), &produce, AtomicRmwOp.Xchg, consumeSignal, AtomicOrder.SeqCst);
            gProducerWakeCount += 1;
            futex_wake(&produce, 1);
        }
    } else {
        while (pContext.counter < max_counter) {
            // Wait for the produce to be the produceSignal
            var produce_val = @noInlineCall(stallWhileDesiredVal, stallCountWait, &produce, consumeSignal);
            //var produce_val = stallWhileDesiredVal(stallCountWait, &produce, consumeSignal);
            while (produce_val == consumeSignal) {
                gProducerWaitCount += 1;
                futex_wait(&produce, consumeSignal);
                produce_val = @atomicLoad(@typeOf(produce), &produce, AtomicOrder.SeqCst);
            }

            // Produce
            gCounter += 1;
            pContext.counter += 1;

            // Tell consumer to consume
            _ = @atomicRmw(@typeOf(produce), &produce, AtomicRmwOp.Xchg, consumeSignal, AtomicOrder.SeqCst);

            // Wake up consumer if needed
            produce_val = @noInlineCall(stallWhileDesiredVal, stallCountWake, &produce, consumeSignal);
            //produce_val = stallWhileDesiredVal(stallCountWake, &produce, consumeSignal);
            if (produce_val == consumeSignal) {
                gProducerWakeCount += 1;
                futex_wake(&produce, 1);
            }
        }
    }
}

fn consumer(pContext: *ThreadContext) void {
    if (pContext.mode == naive) {
        while (pContext.counter < max_counter) {
            // Tell producer to produce
            _ = @atomicRmw(@typeOf(produce), &produce, AtomicRmwOp.Xchg, produceSignal, AtomicOrder.SeqCst);
            gConsumerWakeCount += 1;
            futex_wake(&produce, 1);

            // Wait for producer to produce
            while (@atomicLoad(@typeOf(produce), &produce, AtomicOrder.SeqCst) == produceSignal) {
                gConsumerWaitCount += 1;
                futex_wait(&produce, produceSignal);
            }

            // Consume
            gCounter += 1;
            pContext.counter += 1;
        }
    } else {
        while (pContext.counter < max_counter) {
            // Tell producer to produce
            _ = @atomicRmw(@typeOf(produce), &produce, AtomicRmwOp.Xchg, produceSignal, AtomicOrder.SeqCst);

            // Wake up producer if needed
            var produce_val = @noInlineCall(stallWhileDesiredVal, stallCountWake, &produce, produceSignal);
            //var produce_val = stallWhileDesiredVal(stallCountWake, &produce, produceSignal);
            if (produce_val == produceSignal) {
                gConsumerWakeCount += 1;
                futex_wake(&produce, 1);
            }

            // Wait for producer to produce
            produce_val = @noInlineCall(stallWhileDesiredVal, stallCountWait, &produce, produceSignal);
            //produce_val = stallWhileDesiredVal(stallCountWait, &produce, produceSignal);
            while (produce_val == produceSignal) {
                gConsumerWaitCount += 1;
                futex_wait(&produce, produceSignal);
                produce_val = @atomicLoad(@typeOf(produce), &produce, AtomicOrder.SeqCst);
            }

            // Consume
            gCounter += 1;
            pContext.counter += 1;
        }
    }
}

test "Futex" {
    warn("\ntest Futex:+ gCounter={} gProducerWaitCount={} gConsumerWaitCount={} gProducerWakeCount={} gConsuerWakeCount={}\n",
        gCounter, gProducerWaitCount, gConsumerWaitCount, gProducerWakeCount, gConsumerWakeCount);
    defer warn("test Futex:- gCounter={} gProducerWaitCount={} gConsumerWaitCount={} gProducerWakeCount={} gConsuerWakeCount={}\n",
        gCounter, gProducerWaitCount, gConsumerWaitCount, gProducerWakeCount, gConsumerWakeCount);

    gProducer_context.init(!naive);
    gConsumer_context.init(!naive);

    var timer = try Timer.start();

    var start_time = timer.read();

    var producerThread = try std.os.spawnThread(&gProducer_context, producer);
    var consumerThread = try std.os.spawnThread(&gConsumer_context, consumer);

    producerThread.wait();
    consumerThread.wait();

    var end_time = timer.read();
    var duration = end_time - start_time;
    warn("test Futex: time={.6}\n", @intToFloat(f64, end_time - start_time) / @intToFloat(f64, std.os.time.ns_per_s));

    assert(gCounter == max_counter * 2);
}
