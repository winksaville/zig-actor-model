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

pub const Style = enum {
    Simple,
    Robust,
};

pub fn Mutex(comptime mutexType: Style) type {
    return struct {
        const Self = this;

        const simple = switch(mutexType) {
            Style.Simple => Style.Simple,
            else => @compileError("Only Style.Simple supported"),
        };

        value: usize,
        simpleStyle: Style, // TODO: Don't require a field to get comptime failure

        pub fn init() Self {
            return Self {
                .value = 0,
                .simpleStyle = simple,
            };
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

var gThread0_context: ThreadContext = undefined;
var gThread1_context: ThreadContext = undefined;

var gCounter_mutex = Mutex(Style.Simple).init();
//var gCounter_mutex = Mutex(Style.Robust).init(); Generates a compile time error
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

    var mutex = Mutex(Style.Simple).init();
    assert(mutex.value == 0);

    mutex.lock();
    assert(mutex.value == 1);
    mutex.unlock();
    assert(mutex.value == 0);

    // Initialize gCounter and it's mutex
    gCounter = 0;
    //Mtx.init(gCounter_mutex);

    gThread0_context.init("thread0");
    gThread1_context.init("thread1");
    var thread0 = try std.os.spawnThread(&gThread0_context, threadDispatcher);
    var thread1 = try std.os.spawnThread(&gThread1_context, threadDispatcher);

    warn("call thread0/1.wait\n");
    thread0.wait();
    thread1.wait();
    warn("call after thread0/1.wait\n");

    assert(gCounter == 2000000);
}
