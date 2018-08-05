const std = @import("std");
const assert = std.debug.assert;
const warn = std.debug.warn;
const mem = std.mem;
const math = std.math;

const builtin = @import("builtin");
const AtomicOrder = builtin.AtomicOrder;
const AtomicRmwOp = builtin.AtomicRmwOp;

const linux = switch(builtin.os) {
    builtin.Os.linux => std.os.linux,
    else => @compileError("Only builtin.os.linux is supported"),
};

//pub const posix = switch (builtin.os) {
//    builtin.Os.linux => linux,
//    builtin.Os.macosx, builtin.Os.ios => darwin,
//    builtin.Os.zen => zen,
//    else => @compileError("Unsupported OS"),
//};

pub use switch(builtin.arch) {
    builtin.Arch.x86_64 => @import("../zig/std/os/linux/x86_64.zig"),
    else => @compileError("unsupported arch"),
};

pub fn futex_wait(pVal: *usize, expected_value: usize) void {
    //warn("futex_wait: {*}\n", pVal);
    _ = syscall4(SYS_futex, @ptrToInt(pVal), linux.FUTEX_WAIT, expected_value, 0);
}

pub fn futex_wake(pVal: *usize, num_threads_to_wake: u32) void {
    //warn("futex_wake: {*}\n", pVal);
    _ = syscall4(SYS_futex, @ptrToInt(pVal), linux.FUTEX_WAKE, num_threads_to_wake, 0);
}

pub const Mutex = struct {
    const Self = this;

    value: usize,

    pub fn init(pSelf: *Self) void {
        warn("Mutex.init: pSelf={*}\n", pSelf);
        pSelf.value = 0;
    }

    pub fn lock(pSelf: *Self) void {
        while (@atomicRmw(usize, &pSelf.value, AtomicRmwOp.Xchg, 1, AtomicOrder.SeqCst) != 0) {
            futex_wait(&pSelf.value, 1);
        }
    }

    pub fn unlock(pSelf: *Self) void {
        assert(@atomicRmw(usize, &pSelf.value, AtomicRmwOp.Xchg, 0, AtomicOrder.SeqCst) == 1);
        futex_wake(&pSelf.value, 1);
    }
};

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

var gThread0_context: ThreadContext = undefined;
var gThread1_context: ThreadContext = undefined;

var gCounter_mutex: Mutex = undefined;
var gCounter: u128 = undefined;

fn threadDispatcher(pContext: *ThreadContext) void {
    while (pContext.counter < 1000000) {
        {
            gCounter_mutex.lock();
            defer gCounter_mutex.unlock();
            gCounter += 1;
        }
        pContext.counter += 1;
    }
}

test "Mutex" {
    warn("\ntest Mutex:+ gCounter={}\n", gCounter);
    defer warn("test Mutex:- gCounter={}\n", gCounter);

    var mutex: Mutex = undefined;
    mutex.init();
    warn("test Mutex: mutex={*} mutex.value={}\n", &mutex, mutex.value);

    mutex.lock();
    warn("test Mutex: after lock mutex={*} mutex.value={}\n", &mutex, mutex.value);
    mutex.unlock();
    warn("test Mutex: after unlock mutex={*} mutex.value={}\n", &mutex, mutex.value);

    // Initialize gCoutner and it's mutex
    gCounter = 0;
    gCounter_mutex.init();

    warn("call threadSpawn\n");
    gThread0_context.init("thread0");
    warn("gThread0_context.name len={} name={}\n", gThread0_context.name.len,
            gThread0_context.name[0..gThread0_context.name_len]);
    var thread0 = try std.os.spawnThread(&gThread0_context, threadDispatcher);

    gThread1_context.init("thread1");
    warn("gThread1_context.name len={} name={}\n", gThread1_context.name.len,
            gThread1_context.name[0..gThread1_context.name_len]);
    var thread1 = try std.os.spawnThread(&gThread1_context, threadDispatcher);

    warn("call thread0/1.wait\n");
    thread0.wait();
    //warn("call after thread0.wait\n");
    //warn("call thread1.wait\n");
    thread1.wait();
    warn("call after thread0/1.wait\n");

    assert(gCounter == 2000000);
}
