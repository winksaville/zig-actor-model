// Actor dispatcher

const ActorInterface = @import("actor.zig").ActorInterface;
const MessageHeader = @import("message.zig").MessageHeader;
const AtomicOrder = builtin.AtomicOrder;
const AtomicRmwOp = builtin.AtomicRmwOp;

const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const warn = std.debug.warn;
const MQ = @import("message_queue.zig");
const MessageQueue = MQ.MessageQueue;
const SignalContext = MQ.SignalContext;
const futex_wake = @import("futex.zig").futex_wake;

/// Dispatches messages to actors
pub fn ActorDispatcher(comptime maxActors: usize) type {
    return struct {
        const Self = this;

        pub queue: MessageQueue(),
        pub signalContext: u32,
        pub msg_count: u64,
        pub last_msg_cmd: u64,
        pub actor_processMessage_count: u64,

        // Array of actors
        lock: u8,
        pub actors: [maxActors]*ActorInterface,
        pub actors_count: u64,

        pub inline fn init(pSelf: *Self) void {
            // Because we're using self referential pointers init
            // must be passed a pointer rather then returning Self
            pSelf.queue = MessageQueue().init(signalFn, &pSelf.signalContext);
            pSelf.msg_count = 0;
            pSelf.last_msg_cmd = 0;
            pSelf.actor_processMessage_count = 0;
            pSelf.lock = 0;
            pSelf.actors_count = 0;
            pSelf.actors = undefined;

            warn("ActorDispatcher.init: {*}:&signalContext={*}\n", pSelf, &pSelf.signalContext);
        }

        fn signalFn(pSignalContext: *SignalContext) void {
            warn("ActorDispatcher.signalFn: call wake {*}\n", pSignalContext);
            futex_wake(pSignalContext, 1);
        }


        /// Add an ActorInterface to this dispatcher
        pub fn add(pSelf: *Self, pAi: *ActorInterface) !void {
            warn("ActorDispatcher.add: {*}:&signalContext={*}\n", pSelf, &pSelf.signalContext);
            while (@atomicRmw(u8, &pSelf.lock, AtomicRmwOp.Xchg, 1, AtomicOrder.SeqCst) != 0) {}
            defer assert(@atomicRmw(u8, &pSelf.lock, AtomicRmwOp.Xchg, 0, AtomicOrder.SeqCst) == 1);
            if (pSelf.actors_count >= pSelf.actors.len) return error.TooManyActors;
            pSelf.actors[pSelf.actors_count] = pAi;
            pSelf.actors_count += 1;
            //warn("ActorDispatcher.add: pAi={*} processMessage={x}\n", pAi,
            //    @ptrToInt(pSelf.actors[pSelf.actors_count-1].processMessage));
        }

        pub fn broadcastLoop(pSelf: *Self) void {
            warn("ActorDispatcher.broadcastLoop: {*}:&signalContext={*}\n", pSelf, &pSelf.signalContext);
            while (true) {
                var pMsgHeader = pSelf.queue.get() orelse return;
                pSelf.msg_count += 1;
                pSelf.last_msg_cmd = pMsgHeader.cmd;
                for (pSelf.actors) |pAi, i| {
                    if (i >= pSelf.actors_count) break;
                    if (pAi == null) continue;
                    pSelf.actor_processMessage_count += 1;
                    //warn("ActorDispatcher.broadcast: pAi={*} processMessage={x}\n", pAi,
                    //    @ptrToInt(pAi.processMessage));
                    pAi.processMessage(pAi, pMsgHeader);
                }
            }
        }
    };
}
