const MessageHeader = @import("message.zig").MessageHeader;
const futex_wait = @import("futex.zig").futex_wait;
const futex_wake = @import("futex.zig").futex_wake;

const std = @import("std");
const assert = std.debug.assert;
const warn = std.debug.warn;

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

const SignalContext = u32;

/// A Many producer, single consumer queue of MessageHeaders.
/// Based on std.atomic.Queue
///
/// Uses a spinlock to protect get() and put() and thus is non-blocking
pub fn ActorMessageQueue() type {
    return struct {
        pub const Self = this;

        head: ?*MessageHeader,
        tail: ?*MessageHeader,
        lock: u8,
        signalFn: ?fn(pSignalContext: *SignalContext) void,
        pSignalContext: ?*SignalContext,

        /// Initialize an ActorMessageQueue with optional signalFn and signalContext.
        /// When the first message is added to an empty signalFn is invoked if it
        /// and a signalContext is available. If either are null then the signalFn
        /// will never be invoked.
        pub fn init(signalFn: ?fn(context: *SignalContext) void, pSignalContext: ?*SignalContext) Self {
            return Self{
                .head = null,
                .tail = null,
                .lock = 0,
                .signalFn = signalFn,
                .pSignalContext = pSignalContext,
            };
        }

        pub fn put(pSelf: *Self, mh: *MessageHeader) void {
            mh.next = null;

            while (@atomicRmw(u8, &pSelf.lock, builtin.AtomicRmwOp.Xchg, 1, AtomicOrder.SeqCst) != 0) {}
            defer assert(@atomicRmw(u8, &pSelf.lock, builtin.AtomicRmwOp.Xchg, 0, AtomicOrder.SeqCst) == 1);

            const opt_tail = pSelf.tail;
            pSelf.tail = mh;
            if (opt_tail) |tail| {
                // Append
                //warn("put: append mh={*} cmd={}\n", mh, mh.cmd);
                tail.next = mh;
            } else {
                // Was empty so wakeup any waiters
                assert(pSelf.head == null);
                pSelf.head = mh;
                //warn("put: first entry mh={*} cmd={}\n", mh, mh.cmd);
                if (pSelf.signalFn) |signalFn| {
                    if (pSelf.pSignalContext) |signalContext| {
                        signalFn(signalContext);
                    }
                }
            }
        }

        pub fn get(pSelf: *Self) ?*MessageHeader {
            while (@atomicRmw(u8, &pSelf.lock, builtin.AtomicRmwOp.Xchg, 1, AtomicOrder.SeqCst) != 0) {}
            defer assert(@atomicRmw(u8, &pSelf.lock, builtin.AtomicRmwOp.Xchg, 0, AtomicOrder.SeqCst) == 1);

            const head = pSelf.head orelse {
                //warn("get: return null\n");
                return null;
            };
            pSelf.head = head.next;
            if (head.next == null) {
                pSelf.tail = null;
                //warn("get: returning last entry head={*} cmd={}\n", head, head.cmd);
            }
            //warn("get: return head={*} cmd={}\n", head, head.cmd);
            return head;
        }

        pub fn dump(pSelf: *Self) void {
            while (@atomicRmw(u8, &pSelf.lock, builtin.AtomicRmwOp.Xchg, 1, AtomicOrder.SeqCst) != 0) {}
            defer assert(@atomicRmw(u8, &pSelf.lock, builtin.AtomicRmwOp.Xchg, 0, AtomicOrder.SeqCst) == 1);

            std.debug.warn("head: ");
            dumpRecursive(pSelf.head, 0);
            std.debug.warn("tail: ");
            dumpRecursive(pSelf.tail, 0);
        }

        fn dumpRecursive(optional_mh: ?*MessageHeader, indent: usize) void {
            var stderr_file = std.io.getStdErr() catch return;
            const stderr = &std.io.FileOutStream.init(&stderr_file).stream;
            stderr.writeByteNTimes(' ', indent) catch return;
            if (optional_mh) |mh| {
                std.debug.warn("{*}:cmd={}\n", mh, mh.cmd);
                dumpRecursive(mh.next, indent + 1);
            } else {
                std.debug.warn("(null)\n");
            }
        }
    };
}

const Context = struct {
    allocator: *std.mem.Allocator,
    queue: *ActorMessageQueue(),
    put_sum: u64,
    get_sum: u64,
    get_count: usize,
    puts_done: u8, // TODO make this a bool
};

// TODO add lazy evaluated build options and then put puts_per_thread behind
// some option such as: "AggressiveMultithreadedFuzzTest". In the AppVeyor
// CI we would use a less aggressive setting since at 1 core, while we still
// want this test to pass, we need a smaller value since there is so much thrashing
// we would also use a less aggressive setting when running in valgrind
const puts_per_thread = 500;
const put_thread_count = 3;

test "ActorMessageQueue.multi-threaded" {
    var direct_allocator = std.heap.DirectAllocator.init();
    defer direct_allocator.deinit();

    var plenty_of_memory = try direct_allocator.allocator.alloc(u8, 300 * 1024);
    defer direct_allocator.allocator.free(plenty_of_memory);

    var fixed_buffer_allocator = std.heap.ThreadSafeFixedBufferAllocator.init(plenty_of_memory);
    var a = &fixed_buffer_allocator.allocator;

    var queue = ActorMessageQueue().init(signaler, &signal);
    var context = Context{
        .allocator = a,
        .queue = &queue,
        .put_sum = 0,
        .get_sum = 0,
        .puts_done = 0,
        .get_count = 0,
    };

    var putters: [put_thread_count]*std.os.Thread = undefined;
    for (putters) |*t| {
        t.* = try std.os.spawnThread(&context, startPuts);
    }
    var getter = try std.os.spawnThread(&context, startGetter);

    for (putters) |t|
        t.wait();
    _ = @atomicRmw(u8, &context.puts_done, builtin.AtomicRmwOp.Xchg, 1, AtomicOrder.SeqCst);
    warn("putters are done, signal getter context.puts_done={}\n", context.puts_done);
    signaler(&signal);
    getter.wait();

    if (context.put_sum != context.get_sum) {
        std.debug.panic("failure\nput_sum:{} != get_sum:{}", context.put_sum, context.get_sum);
    }

    if (context.get_count != puts_per_thread * put_thread_count) {
        std.debug.panic(
            "failure\nget_count:{} != puts_per_thread:{} * put_thread_count:{}",
            context.get_count,
            u32(puts_per_thread),
            u32(put_thread_count),
        );
    }
}

fn startPuts(ctx: *Context) u8 {
    var put_count: usize = puts_per_thread;
    var r = std.rand.DefaultPrng.init(0xdeadbeef);
    while (put_count != 0) : (put_count -= 1) {
        std.os.time.sleep(0, 1); // let the os scheduler be our fuzz
        const x = r.random.scalar(u64);
        const mh = ctx.allocator.create(MessageHeader {
            .next = undefined,
            .cmd = x,
        }) catch unreachable;
        ctx.queue.put(mh);
        _ = @atomicRmw(u64, &ctx.put_sum, builtin.AtomicRmwOp.Add, x, AtomicOrder.SeqCst);
    }
    return 0;
}

fn startGetter(ctx: *Context) u8 {
    while (true) {
        while (ctx.queue.get()) |mh| {
            std.os.time.sleep(0, 1); // let the os scheduler be our fuzz
            _ = @atomicRmw(u64, &ctx.get_sum, builtin.AtomicRmwOp.Add, mh.cmd, builtin.AtomicOrder.SeqCst);
            _ = @atomicRmw(usize, &ctx.get_count, builtin.AtomicRmwOp.Add, 1, builtin.AtomicOrder.SeqCst);
        }

        if (@atomicLoad(u8, &ctx.puts_done, builtin.AtomicOrder.SeqCst) == 1) {
            warn("startGetter: puts_done=1\n");
            return 0;
        } else {
            warn("startGetter: waiting on signal\n");
            futex_wait(&signal, 0);
            warn("startGetter: wokeup\n");
        }
    }
}

var signal: u32 = 0;
var signal_count: u32 = 0;

fn signaler(pSignalContext: *SignalContext) void {
    _ = @atomicRmw(u32, &signal_count, builtin.AtomicRmwOp.Add, 1, builtin.AtomicOrder.SeqCst);
    //warn("signaler: call wake {*}\n", pSignalContext);
    futex_wake(pSignalContext, 1);
}

test "ActorMessageQueue.single-threaded" {
    var queue = ActorMessageQueue().init(signaler, &signal);

    var mh_0 = MessageHeader {
        .cmd = 0,
        .next = undefined,
    };
    queue.put(&mh_0);
    assert(signal_count == 1);
    assert(queue.get().?.cmd == 0);
    assert(signal_count == 1);
    queue.put(&mh_0);
    assert(signal_count == 2);

    var mh_1 = MessageHeader {
        .cmd = 1,
        .next = undefined,
    };
    queue.put(&mh_1);
    assert(signal_count == 2);
    assert(queue.get().?.cmd == 0);
    assert(signal_count == 2);

    var mh_2 = MessageHeader {
        .cmd = 2,
        .next = undefined,
    };
    queue.put(&mh_2);

    var mh_3 = MessageHeader {
        .cmd = 3,
        .next = undefined,
    };
    queue.put(&mh_3);

    assert(queue.get().?.cmd == 1);

    assert(queue.get().?.cmd == 2);

    var mh_4 = MessageHeader {
        .cmd = 4,
        .next = undefined,
    };
    queue.put(&mh_4);

    assert(queue.get().?.cmd == 3);
    mh_3.next = null;

    assert(queue.get().?.cmd == 4);

    assert(queue.get() == null);
}
