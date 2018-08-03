// Actor dispatcher

const ActorInterface = @import("actor.zig").ActorInterface;
const MessageHeader = @import("message.zig").MessageHeader;
const AtomicOrder = builtin.AtomicOrder;
const AtomicRmwOp = builtin.AtomicRmwOp;

const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const warn = std.debug.warn;
const Queue = std.atomic.Queue;

/// Dispatches messages to actors
pub fn ActorDispatcher(comptime maxActors: usize) type {
    return struct {
        const Self = this;

        pub queue: Queue(*MessageHeader),
        pub msg_count: u64,
        pub last_msg_cmd: u64,
        pub actor_processMessage_count: u64,

        // Array of actors
        lock: u8,
        pub actors: [maxActors]*ActorInterface,
        pub actors_count: u64,

        pub fn init() Self {
            return Self {
                .queue = Queue(*MessageHeader).init(),
                .msg_count = 0,
                .last_msg_cmd = 0,
                .actor_processMessage_count = 0,
                .lock = 0,
                .actors_count = 0,
                .actors = undefined,
            };
        }

        /// Add an ActorInterface to this dispatcher
        pub fn add(pSelf: *Self, pAi: *ActorInterface) !void {
            while (@atomicRmw(u8, &pSelf.lock, AtomicRmwOp.Xchg, 1, AtomicOrder.SeqCst) != 0) {}
            defer assert(@atomicRmw(u8, &pSelf.lock, AtomicRmwOp.Xchg, 0, AtomicOrder.SeqCst) == 1);
            if (pSelf.actors_count >= pSelf.actors.len) return error.TooManyActors;
            pSelf.actors[pSelf.actors_count] = pAi;
            pSelf.actors_count += 1;
            //warn("ActorDispatcher.add: pAi={*} processMessage={x}\n", pAi,
            //    @ptrToInt(pSelf.actors[pSelf.actors_count-1].processMessage));
        }

        pub fn broadcastLoop(pSelf: *Self) void {
            while (true) {
                var pMsgNode = pSelf.queue.get() orelse return;
                pSelf.msg_count += 1;
                pSelf.last_msg_cmd = pMsgNode.data.cmd;
                for (pSelf.actors) |pAi, i| {
                    if (i >= pSelf.actors_count) break;
                    if (pAi == null) continue;
                    pSelf.actor_processMessage_count += 1;
                    //warn("ActorDispatcher.broadcast: pAi={*} processMessage={x}\n", pAi,
                    //    @ptrToInt(pAi.processMessage));
                    pAi.processMessage(pAi, pMsgNode.data);
                }
            }
        }
    };
}
