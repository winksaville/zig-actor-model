// Create a Message that supports arbitrary data
// and can be passed between entities via a Queue.

const actorNs = @import("actor.zig");
const Actor = actorNs.Actor;
const ActorInterface = actorNs.ActorInterface;

const futexNs = @import("futex.zig");
const futex_wait = futexNs.futex_wait;
const futex_wake = futexNs.futex_wake;

const msgNs = @import("message.zig");
const Message = msgNs.Message;
const MessageHeader = msgNs.MessageHeader;

const messageQueueNs = @import("message_queue.zig");
const SignalContext = messageQueueNs.SignalContext;

const MessageAllocator = @import("message_allocator.zig").MessageAllocator;

const ActorDispatcher = @import("actor_dispatcher.zig").ActorDispatcher;

const std = @import("std");
const bufPrint = std.fmt.bufPrint;
const assert = std.debug.assert;
const warn = std.debug.warn;
const mem = std.mem;
const math = std.math;

const builtin = @import("builtin");
const AtomicOrder = builtin.AtomicOrder;
const AtomicRmwOp = builtin.AtomicRmwOp;

const Ball = packed struct {
    const Self = @This();

    hits: u64,

    fn init(pSelf: *Self) void {
        //warn("{*}.init()\n", pSelf);
        pSelf.hits = 0;
    }

    pub fn format(
        pSelf: *const Self,
        comptime fmt: []const u8,
        context: var,
        comptime FmtError: type,
        output: fn (@typeOf(context), []const u8) FmtError!void
    ) FmtError!void {
        try std.fmt.format(context, FmtError, output, "hits={}", pSelf.hits);
    }
};

const Player = struct {
    const Self = @This();

    allocator: MessageAllocator(),
    hits: u64,
    max_hits: u64,
    last_ball_hits: u64,

    fn init(pSelf: *Actor(Player)) void {
        pSelf.body.hits = 0;
        pSelf.body.max_hits = 0;
        pSelf.body.last_ball_hits = 0;

        // Should not fail, error out in safy builds
        pSelf.body.allocator.init(10, 0) catch unreachable;
    }

    fn initDone(pSelf: *Actor(Player), pDone: *Done) void {
        pSelf.body.pDone = pDone;
    }

    fn hitBall(pSelf: *Actor(Player), cmd: u64, pMsg: *Message(Ball)) !void {
        var pResponse = pSelf.body.allocator.get(Message(Ball)) orelse return; // error.NoMessages;
        pResponse.init(cmd);
        pResponse.header.initSwap(&pMsg.header);
        pResponse.body.hits = pMsg.body.hits + 1;
        try pResponse.send();
        //warn("{*}.hitBall pResponse={}\n\n", pSelf, pResponse);
    }

    pub fn processMessage(pActorInterface: *ActorInterface, pMsgHeader: *MessageHeader) void {
        var pSelf: *Actor(Player) = Actor(Player).getActorPtr(pActorInterface);
        var pMsg = Message(Ball).getMessagePtr(pMsgHeader);

        //warn("{*}.processMessage pMsg={}\n", pSelf, pMsg);
        switch(pMsg.header.cmd) {
            0 => {
                warn("{*}.processMessage START pMsgHeader={*} cmd={}\n", pSelf, pMsgHeader, pMsgHeader.cmd);
                // First Ball
                Player.hitBall(pSelf, 1, pMsg) catch |err| warn("error hitBall={}\n", err);
            },
            1 => {
                //warn("{*}.processMessage ONE pMsgHeader={*} cmd={}\n", pSelf, pMsgHeader, pMsgHeader.cmd);
                pSelf.body.hits += 1;
                pSelf.body.last_ball_hits = pMsg.body.hits;
                if (pSelf.body.hits <= pSelf.body.max_hits) {
                    // Regular Balls
                    Player.hitBall(pSelf, 1, pMsg) catch |err| warn("error hitBall={}\n", err);
                } else {
                    // Last ball
                    warn("{*}.processMessage LASTBALL pMsgHeader={*} cmd={} hits={}\n",
                        pSelf, pMsgHeader, pMsgHeader.cmd, pSelf.body.hits);
                    if (pSelf.interface.doneFn) |doneFn| {
                        warn("{*}.processMessage DONE pMsgHeader={*} cmd={} hits={} call doneFn\n",
                            pSelf, pMsgHeader, pMsgHeader.cmd, pSelf.body.hits);
                        doneFn(pSelf.interface.doneFn_handle);
                    }
                    // Tell partner game over
                    warn("{*}.processMessage TELLPRTR pMsgHeader={*} cmd={} hits={}\n",
                        pSelf, pMsgHeader, pMsgHeader.cmd, pSelf.body.hits);
                    Player.hitBall(pSelf, 2, pMsg) catch |err| warn("error hitBall={}\n", err);
                }
            },
            2 => {
                if (pSelf.interface.doneFn) |doneFn| {
                    warn("{*}.processMessage GAMEOVER pMsgHeader={*} cmd={} hits={} call doneFn\n",
                        pSelf, pMsgHeader, pMsgHeader.cmd, pSelf.body.hits);
                    doneFn(pSelf.interface.doneFn_handle);
                    warn("{*}.processMessage GAMEOVER pMsgHeader={*} cmd={} hits={} aftr doneFn\n",
                        pSelf, pMsgHeader, pMsgHeader.cmd, pSelf.body.hits);
                }
            },
            else => {
                // Ignore unknown commands
                warn("{*}.processMessage IGNORE pMsgHeader={*} cmd={} hits={}\n",
                    pSelf, pMsgHeader, pMsgHeader.cmd, pSelf.body.hits);
            },
        }

        // TODO: Should process message be responsible for returning message?
        if (pMsg.header.pAllocator) |pAllocator| pAllocator.put(pMsgHeader);
    }
};

test "actors-single-threaded" {
    // Create Dispatcher
    const Dispatcher = ActorDispatcher(2);
    var dispatcher: Dispatcher = undefined;
    dispatcher.init();

    // Create a PlayerActor type
    const PlayerActor = Actor(Player);
    const max_hits = 10;

    // Create player0
    var player0 = PlayerActor.init();
    player0.body.max_hits = max_hits;
    assert(player0.body.hits == 0);
    try dispatcher.add(&player0.interface);

    // Create player1
    var player1 = PlayerActor.init();
    player1.body.max_hits = max_hits;
    assert(player1.body.hits == 0);
    try dispatcher.add(&player1.interface);

    // Create a message to get things going
    var ballMsg: Message(Ball) = undefined;
    ballMsg.init(0); // Initializes Message.header.cmd to 0 and calls Ball.init()
                     // via Ball.init(&Message.body). Does NOT init any other header fields!

    // Initialize header fields
    ballMsg.header.pAllocator = null;
    ballMsg.header.pDstActor = &player0.interface;
    ballMsg.header.pSrcActor = &player1.interface;

    // Send the message
    try ballMsg.send();

    // Dispatch messages until there are no messages to process
    _ = dispatcher.loop();

    // Validate players hit the ball the expected number of times.
    assert(player0.body.hits > 0);
    assert(player1.body.hits > 0);
    assert(player1.body.last_ball_hits > 0);
    assert(player0.body.hits + player1.body.hits == player1.body.last_ball_hits);
}

const ThreadContext = struct {
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
        warn("ThreadContext.init:+ name={}\n", pSelf.name);
        defer warn("ThreadContext.init:- name={}\n", pSelf.name);

        pSelf.dispatcher.init();
    }

    // TODO: How to support multiple ActorDispatchers?
    fn threadDispatcherFn(pSelf: *ThreadContext) void {
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
        var pContext = @intToPtr(*ThreadContext, doneFn_handle);
        //warn("TD{}DONE{}+\n", pContext.idn, @atomicLoad(u8, &pContext.done, AtomicOrder.SeqCst));
        _ = @atomicRmw(u8, &pContext.done, AtomicRmwOp.Xchg, 1, AtomicOrder.SeqCst);
        _ = @atomicRmw(SignalContext, &pContext.dispatcher.signal_context, AtomicRmwOp.Xchg, 1, AtomicOrder.SeqCst);
        futex_wake(&pContext.dispatcher.signal_context, 1);
        //warn("TD{}DONE{}-\n", pContext.idn, @atomicLoad(u8, &pContext.done, AtomicOrder.SeqCst));
    }
};

var thread0_context: ThreadContext = undefined;
var thread1_context: ThreadContext = undefined;

test "actors-multi-threaded" {
    warn("\ncall thread_context init's\n");
    thread0_context.init(0, "thread0");
    thread1_context.init(1, "thread1");

    var thread0 = try std.os.spawnThread(&thread0_context, ThreadContext.threadDispatcherFn);
    var thread1 = try std.os.spawnThread(&thread1_context, ThreadContext.threadDispatcherFn);
    warn("threads Spawned\n");

    // Create a PlayerActor type
    const PlayerActor = Actor(Player);
    const max_hits = 10;

    // Create player0
    var player0 = PlayerActor.initFull(ThreadContext.threadDoneFn, @ptrToInt(&thread0_context));
    player0.body.max_hits = max_hits;
    assert(player0.body.hits == 0);
    warn("add player0\n");
    try thread0_context.dispatcher.add(&player0.interface);

    // Create player1
    var player1 = PlayerActor.initFull(ThreadContext.threadDoneFn, @ptrToInt(&thread1_context));
    player1.body.max_hits = max_hits;
    assert(player1.body.hits == 0);
    warn("add player1\n");
    try thread1_context.dispatcher.add(&player1.interface);

    // Create a message to get things going
    warn("create start message\n");
    var ballMsg: Message(Ball) = undefined;
    ballMsg.init(0); // Initializes Message.header.cmd to 0 and calls Ball.init()
                     // via Ball.init(&Message.body). Does NOT init any other header fields!

    // Initialize header fields
    ballMsg.header.pAllocator = null;
    ballMsg.header.pDstActor = &player0.interface;
    ballMsg.header.pSrcActor = &player1.interface;
    warn("ballMsg={}\n", &ballMsg);

    // Send the message
    try ballMsg.send();

    // Order of waiting does not mater
    warn("call wait thread1\n");
    thread1.wait();
    warn("aftr wait thread1\n");
    warn("call wait thread0\n");
    thread0.wait();
    warn("aftr wait thread0\n");

    // Validate players hit the ball the expected number of times.
    assert(player0.body.hits > 0);
    assert(player1.body.hits > 0);
    assert(player1.body.last_ball_hits > 0);
    assert(player0.body.hits + player1.body.hits == player1.body.last_ball_hits);
}
