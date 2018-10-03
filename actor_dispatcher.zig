// Actor dispatcher

const actorNs = @import("actor.zig");
const ActorInterface = actorNs.ActorInterface;

const messageNs = @import("message.zig");
const MessageHeader = messageNs.MessageHeader;

const messageQueueNs = @import("message_queue.zig");
const MessageQueue = messageQueueNs.MessageQueue;
const SignalContext = messageQueueNs.SignalContext;

const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const warn = std.debug.warn;

const futex_wake = @import("futex.zig").futex_wake;
const AtomicOrder = builtin.AtomicOrder;
const AtomicRmwOp = builtin.AtomicRmwOp;

/// Dispatches messages to actors
pub fn ActorDispatcher(comptime maxActors: usize) type {
    return struct {
        const Self = @This();

        // TODO: Should there be one queue per actor instead?
        pub queue: MessageQueue(),
        pub signal_context: u32,
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

            warn("ActorDispatcher.init:+ {*}:&signal_context={*}\n", pSelf, &pSelf.signal_context);
            defer warn("ActorDispatcher.init:- {*}:&signal_context={*}\n", pSelf, &pSelf.signal_context);
            pSelf.signal_context = 0;
            pSelf.queue = MessageQueue().init(Self.signalFn, &pSelf.signal_context);
            pSelf.msg_count = 0;
            pSelf.last_msg_cmd = 0;
            pSelf.actor_processMessage_count = 0;
            pSelf.lock = 0;
            pSelf.actors_count = 0;
            pSelf.actors = undefined;
        }

        /// Add an ActorInterface to this dispatcher
        pub fn add(pSelf: *Self, pAi: *ActorInterface) !void {
            warn("ActorDispatcher.add:+ {*}:&signal_context={*} pAi={*} processMessage={x}\n",
                    pSelf, &pSelf.signal_context, pAi, @ptrToInt(pAi.processMessage));
            while (@atomicRmw(u8, &pSelf.lock, AtomicRmwOp.Xchg, 1, AtomicOrder.SeqCst) == 0) {}
            defer assert(@atomicRmw(u8, &pSelf.lock, AtomicRmwOp.Xchg, 0, AtomicOrder.SeqCst) == 1);
            if (pSelf.actors_count >= pSelf.actors.len) return error.TooManyActors;
            pAi.pQueue = &pSelf.queue;
            pSelf.actors[pSelf.actors_count] = pAi;
            pSelf.actors_count += 1;
            //warn("ActorDispatcher.add:- {*}:&signal_context={*} pAi={*} processMessage={x}\n",
            //    pSelf, &pSelf.signal_context, pAi, @ptrToInt(pSelf.actors[pSelf.actors_count-1].processMessage));
        }

        fn signalFn(pSignalContext: *SignalContext) void {
            //warn("ActorDispatcher.signalFn:+ call wake {*}:{}\n", pSignalContext, pSignalContext.*);
            //defer warn("ActorDispatcher.signalFn:- aftr wake {*}:{}\n", pSignalContext, pSignalContext.*);

            // Set signal_context and get old value which if 0 then we know the thread is or has gone to sleep.
            // So we'll call futex_wake as there is only one ActorDispatcher per thread. In the future,
            // if/when there are multiple ActorDispatchers per thread this might need to change.
            if (0 == @atomicRmw(SignalContext, pSignalContext, AtomicRmwOp.Xchg, 1, AtomicOrder.SeqCst)) {
                //warn("ActorDispatcher.signalFn: call wake {*}:{}\n", pSignalContext, pSignalContext.*);
                futex_wake(pSignalContext, 1);
            }
        }

        /// Loop through the message on the queue calling
        /// the associated actor.
        /// @return true if queue is empty
        pub fn loop(pSelf: *Self) bool {
            //warn("ActorDispatcher.loop:+ {*}:&signal_context={*}\n", pSelf, &pSelf.signal_context);
            //defer warn("ActorDispatcher.loop:- {*}:&signal_context={*}\n", pSelf, &pSelf.signal_context);

            // TODO: limit number of loops or time so we don't starve other actors
            // that we maybe sharing the thread with.
            while (true) {
                // Return if queue is empty
                var pMsgHeader = pSelf.queue.get() orelse {
                    // We're racing with signalFn if we win and store the 0 then
                    // we "know" we're going to sleep as right now there is only
                    // one ActorDispatcher per thread. When/if there ever is more
                    // than one then we need to change this and signalFn.
                    return @atomicRmw(SignalContext, &pSelf.signal_context, AtomicRmwOp.Xchg, 0, AtomicOrder.SeqCst) == 0;
                };

                pSelf.msg_count += 1;
                pSelf.last_msg_cmd = pMsgHeader.cmd;
                if (pMsgHeader.pDstActor) |pAi| {
                    if (pAi.pQueue) |pQ| {
                        if (pQ == &pSelf.queue) {
                            pAi.processMessage(pAi, pMsgHeader);
                        } else {
                            // TODO: Actor is associated with a
                            // different "dispatcher/queue". We
                            // could:
                            //   - put it on the other queue but
                            //     ordering could change.
                            //   - drop it
                            //   - send back to src with an error

                            // Right now this isn't possible so we'll
                            // mark it as unreachable.
                            unreachable;
                        }
                    } else {
                        // TODO: No destination queue just drop??
                        if (pMsgHeader.pAllocator) |pAllocator| {
                            pAllocator.put(pMsgHeader);
                        }
                    }
                } else {
                    // TODO: No destination actor just drop??
                    if (pMsgHeader.pAllocator) |pAllocator| {
                        pAllocator.put(pMsgHeader);
                    }
                }
            }
        }

        pub fn broadcastLoop(pSelf: *Self) void {
            //warn("ActorDispatcher.broadcastLoop:+ {*}:&signal_context={*}\n", pSelf, &pSelf.signal_context);
            //defer warn("ActorDispatcher.broadcastLoop:- {*}:&signal_context={*}\n", pSelf, &pSelf.signal_context);
            while (true) {
                var pMsgHeader = pSelf.queue.get() orelse return;
                pSelf.msg_count += 1;
                pSelf.last_msg_cmd = pMsgHeader.cmd;
                var i: usize = 0;
                while (i < pSelf.actors_count) : (i += 1) {
                    var pAi = pSelf.actors[i];
                    pSelf.actor_processMessage_count += 1;
                    //warn("ActorDispatcher.broadcast: pAi={*} processMessage={x}\n", pAi,
                    //    @ptrToInt(pAi.processMessage));
                    pAi.processMessage(pAi, pMsgHeader);
                }
            }
        }
    };
}

// Tests

const Message = messageNs.Message;
const Actor = actorNs.Actor;
const mem = std.mem;

const MyMsgBody = packed struct {
    const Self = @This();
    data: [3]u8,

    fn init(pSelf: *Self) void {
        mem.set(u8, pSelf.data[0..], 'Z');
    }

    pub fn format(
        m: *const MyMsgBody,
        comptime fmt: []const u8,
        context: var,
        comptime FmtError: type,
        output: fn (@typeOf(context), []const u8) FmtError!void
    ) FmtError!void {
        try std.fmt.format(context, FmtError, output, "data={{");
        for (m.data) |v| {
            if ((v >= ' ') and (v <= 0x7f)) {
                try std.fmt.format(context, FmtError, output, "{c}," , v);
            } else {
                try std.fmt.format(context, FmtError, output, "{x},", v);
            }
        }
        try std.fmt.format(context, FmtError, output, "}},");
    }
};

const MyActorBody = packed struct {
    const Self = @This();

    count: u64,

    fn init(actr: *Actor(MyActorBody)) void {
        actr.body.count = 0;
    }

    pub fn processMessage(actorInterface: *ActorInterface, msgHeader: *MessageHeader) void {
        var pActor = Actor(MyActorBody).getActorPtr(actorInterface);
        var pMsg = Message(MyMsgBody).getMessagePtr(msgHeader);
        assert(pMsg.header.cmd == msgHeader.cmd);

        pActor.body.count += pMsg.header.cmd;
        //warn("MyActorBody: &processMessage={x} cmd={} count={}\n",
        //    @ptrToInt(processMessage), msgHeader.cmd, pActor.body.count);
    }
};

test "ActorDispatcher" {
    // Create a message
    const MyMsg = Message(MyMsgBody);
    var myMsg: MyMsg = undefined;
    myMsg.init(123);

    // Create an Actor
    const MyActor = Actor(MyActorBody);
    var myActor = MyActor.init();

    myActor.interface.processMessage(&myActor.interface, &myMsg.header);
    assert(myActor.body.count == 1 * 123);
    myActor.interface.processMessage(&myActor.interface, &myMsg.header);
    assert(myActor.body.count == 2 * 123);

    const MyActorDispatcher = ActorDispatcher(5);
    var myActorDispatcher: MyActorDispatcher = undefined;
    myActorDispatcher.init();
    assert(myActorDispatcher.actors_count == 0);
    try myActorDispatcher.add(&myActor.interface);
    assert(myActorDispatcher.actors_count == 1);
    assert(myActorDispatcher.actors[0].processMessage == myActor.interface.processMessage);

    // Place the node on the queue and broadcast to the actors
    myActorDispatcher.queue.put(&myMsg.header);
    myActorDispatcher.broadcastLoop();
    assert(myActorDispatcher.last_msg_cmd == 123);
    assert(myActorDispatcher.msg_count == 1);
    assert(myActorDispatcher.actor_processMessage_count == 1);
    assert(myActor.body.count == 3 * 123);
}
