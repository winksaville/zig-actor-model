const std = @import("std");
const mem = std.mem;
const math = std.math;
const warn = std.debug.warn;

const futexNs = @import("futex.zig");
const futex_wait = futexNs.futex_wait;
const futex_wake = futexNs.futex_wake;

const builtin = @import("builtin");
const AtomicOrder = builtin.AtomicOrder;
const AtomicRmwOp = builtin.AtomicRmwOp;

const messageQueueNs = @import("message_queue.zig");
const SignalContext = messageQueueNs.SignalContext;

const ActorDispatcher = @import("actor_dispatcher.zig").ActorDispatcher;

pub const ActorThreadContext = struct {
    const Self = @This();

    idn: u8,
    name_len: usize,
    name: [32]u8,
    done: u8,
    dispatcher: ActorDispatcher(1),

    pub fn init(pSelf: *Self, idn: u8, name: [] const u8) void {
        // Set name_len and then copy with truncation
        pSelf.idn = idn;
        pSelf.name_len = math.min(name.len, pSelf.name.len);
        mem.copy(u8, pSelf.name[0..pSelf.name_len], name[0..pSelf.name_len]);
        warn("ActorThreadContext.init:+ name={}\n", pSelf.name);
        defer warn("ActorThreadContext.init:- name={}\n", pSelf.name);

        pSelf.dispatcher.init();
    }

    // TODO: How to support multiple ActorDispatchers?
    fn threadDispatcherFn(pSelf: *ActorThreadContext) void {
        warn("threadDispatcherFn:+ {}\n", pSelf.name);
        defer warn("threadDispatcherFn:- {}\n", pSelf.name);

        while (@atomicLoad(u8, &pSelf.done, AtomicOrder.SeqCst) == 0) {
            if (pSelf.dispatcher.loop()) {
                //warn("TD{}WAIT\n", pSelf.idn);
                futex_wait(&pSelf.dispatcher.signal_context, 0);
            }
        }
    }

    // TODO: How to support multiple ActorDispatchers?
    fn threadDoneFn(doneFn_handle: usize) void {
        var pContext = @intToPtr(*ActorThreadContext, doneFn_handle);
        _ = @atomicRmw(u8, &pContext.done, AtomicRmwOp.Xchg, 1, AtomicOrder.SeqCst);
        _ = @atomicRmw(SignalContext, &pContext.dispatcher.signal_context, AtomicRmwOp.Xchg, 1, AtomicOrder.SeqCst);
        futex_wake(&pContext.dispatcher.signal_context, 1);
    }
};

//pub fn ActorModel(comptime threads: usize) type {
//    return struct {
//        
//    };
//}
