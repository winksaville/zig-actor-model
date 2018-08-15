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
    const Self = this;

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

const PlayerBody = struct {
    const Self = this;

    allocator: MessageAllocator(),
    hits: u64,
    max_hits: u64,
    last_ball_hits: u64,

    fn init(pSelf: *Actor(PlayerBody)) void {
        pSelf.body.hits = 0;
        pSelf.body.max_hits = 0;
        pSelf.body.last_ball_hits = 0;

        // Should not fail, error out in safy builds
        pSelf.body.allocator.init(10, 0) catch unreachable;
    }

    fn initDone(pSelf: *Actor(PlayerBody), pDone: *Done) void {
        pSelf.body.pDone = pDone;
    }

    fn hitBall(pSelf: *Actor(PlayerBody), cmd: u64, pMsg: *Message(Ball)) !void {
        var pResponse = pSelf.body.allocator.get(Message(Ball)) orelse return; // error.NoMessages;
        pResponse.init(cmd);
        pResponse.header.initSwap(&pMsg.header);
        pResponse.body.hits = pMsg.body.hits + 1;
        try pResponse.send();
        //warn("{*}.hitBall pResponse={}\n\n", pSelf, pResponse);
    }

    pub fn processMessage(pActorInterface: *ActorInterface, pMsgHeader: *MessageHeader) void {
        var pSelf: *Actor(PlayerBody) = Actor(PlayerBody).getActorPtr(pActorInterface);
        var pMsg = Message(Ball).getMessagePtr(pMsgHeader);

        //warn("{*}.processMessage pMsg={}\n", pSelf, pMsg);
        switch(pMsg.header.cmd) {
            0 => {
                warn("{*}.processMessage START pMsgHeader={*} cmd={}\n", pSelf, pMsgHeader, pMsgHeader.cmd);
                // First Ball
                PlayerBody.hitBall(pSelf, 1, pMsg) catch |err| warn("error hitBall={}\n", err);
            },
            1 => {
                //warn("{*}.processMessage ONE pMsgHeader={*} cmd={}\n", pSelf, pMsgHeader, pMsgHeader.cmd);
                pSelf.body.hits += 1;
                pSelf.body.last_ball_hits = pMsg.body.hits;
                if (pSelf.body.hits <= pSelf.body.max_hits) {
                    // Regular Balls
                    PlayerBody.hitBall(pSelf, 1, pMsg) catch |err| warn("error hitBall={}\n", err);
                } else {
                    // Last ball
                    //warn("{*}.processMessage LASTBALL pMsgHeader={*} cmd={} hits={}\n",
                    //    pSelf, pMsgHeader, pMsgHeader.cmd, pSelf.body.hits);
                    if (pSelf.interface.doneFn) |doneFn| {
                        //warn("{*}.processMessage DONE pMsgHeader={*} cmd={} hits={} call doneFn\n",
                        //    pSelf, pMsgHeader, pMsgHeader.cmd, pSelf.body.hits);
                        doneFn(pSelf.interface.doneFn_handle);
                    }
                    // Tell partner game over
                    //warn("{*}.processMessage TELLPRTR pMsgHeader={*} cmd={} hits={}\n",
                    //    pSelf, pMsgHeader, pMsgHeader.cmd, pSelf.body.hits);
                    PlayerBody.hitBall(pSelf, 2, pMsg) catch |err| warn("error hitBall={}\n", err);
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

    // Create a Player type
    const Player = Actor(PlayerBody);
    const max_hits = 10;

    // Create player0
    var player0 = Player.init();
    player0.body.max_hits = max_hits;
    assert(player0.body.hits == 0);
    try dispatcher.add(&player0.interface);

    // Create player1
    var player1 = Player.init();
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
    dispatcher.loop();

    // Validate players hit the ball the expected number of times.
    assert(player0.body.hits > 0);
    assert(player1.body.hits > 0);
    assert(player1.body.last_ball_hits > 0);
    assert(player0.body.hits + player1.body.hits == player1.body.last_ball_hits);
}

const ThreadContext = struct {
    const Self = this;

    idn: u8,
    name_len: usize,
    name: [32]u8,
    done: u8,
    dispatcher: ActorDispatcher(1),

    player: *Actor(PlayerBody),

    pub fn init(pSelf: *Self, idn: u8, name: [] const u8) void {
        // Set name_len and then copy with truncation
        pSelf.idn = idn;
        pSelf.name_len = math.min(name.len, pSelf.name.len);
        mem.copy(u8, pSelf.name[0..pSelf.name_len], name[0..pSelf.name_len]);
        warn("ThreadContext.init:+ name={}\n", pSelf.name);
        defer warn("ThreadContext.init:- name={}\n", pSelf.name);

        pSelf.dispatcher.init();
    }
};

// TODO: This should be able to reside in ThreadContext but a compile error occurs
fn threadDispatcher(pSelf: *ThreadContext) void {
    warn("threadDispatcher:+ {}\n", pSelf.name);
    defer warn("threadDispatcher:- {}\n", pSelf.name);

    while (@atomicLoad(u8, &pSelf.done, AtomicOrder.SeqCst) == 0) {
        pSelf.dispatcher.loop();

        // TODO: Having two critical sections feels racy and is probably wrong!!!
        if (@atomicLoad(u8, &pSelf.done, AtomicOrder.SeqCst) == 1) return;

        if (@atomicLoad(SignalContext, &pSelf.dispatcher.signal_context, AtomicOrder.SeqCst) == 0) {
            //warn("TD{}WAIT\n", pSelf.idn);
            futex_wait(&pSelf.dispatcher.signal_context, 0);
            //warn("TD{}RSUM{}\n", pSelf.idn, @atomicLoad(u8, &pSelf.done, AtomicOrder.SeqCst));
        }
        _ = @atomicRmw(SignalContext, &pSelf.dispatcher.signal_context, AtomicRmwOp.Xchg, 0, AtomicOrder.SeqCst);
        //warn("TD{}LOOP{}-\n", pSelf.idn, @atomicLoad(u8, &pSelf.done, AtomicOrder.SeqCst));
    }
}

// TODO: This should be able to reside in ThreadContext but a compile error occurs
fn threadDoneFn(doneFn_handle: usize) void {
    var pContext = @intToPtr(*ThreadContext, doneFn_handle);
    //warn("TD{}DONE{}+\n", pContext.idn, @atomicLoad(u8, &pContext.done, AtomicOrder.SeqCst));
    assert(@atomicRmw(u8, &pContext.done, AtomicRmwOp.Xchg, 1, AtomicOrder.SeqCst) == 0);
    futex_wake(&pContext.dispatcher.signal_context, 1);
    //warn("TD{}DONE{}-\n", pContext.idn, @atomicLoad(u8, &pContext.done, AtomicOrder.SeqCst));
}

var thread0_context: ThreadContext = undefined;
var thread1_context: ThreadContext = undefined;

test "actors-multi-threaded" {
    warn("call thread_context init's\n");
    thread0_context.init(0, "thread0");
    thread1_context.init(1, "thread1");

    warn("call threadSpawn\n");
    var thread0 = try std.os.spawnThread(&thread0_context, threadDispatcher);
    var thread1 = try std.os.spawnThread(&thread1_context, threadDispatcher);

    //Causes zig compiler to crash at a zig_unreachable in hash_const_val()
    //case TypeTableEntryIdUnreachable: in src/analyze.cpp approx line 4762
    //var thread0 = try std.os.spawnThread(&thread0_context, thread0_context.threadDispatcher);
    //var thread1 = try std.os.spawnThread(&thread1_context, thread1_context.threadDispatcher);

    // Create a Player type
    const Player = Actor(PlayerBody);
    const max_hits = 10;

    // Create player0
    //Causes error: expected type '?fn(usize) void', found '(bound fn(usize) void)'
    //var player0 = Player.initFull(thread0_context.doneFn, @ptrToInt(&thread0_context));
    var player0 = Player.initFull(threadDoneFn, @ptrToInt(&thread0_context));
    player0.body.max_hits = max_hits;
    assert(player0.body.hits == 0);
    warn("add player0\n");
    thread0_context.player = &player0;
    try thread0_context.dispatcher.add(&player0.interface);
    //warn("after dispatcher.add 66666666666666666666666666666\n");
    //std.os.time.sleep(1, 1000000);
    //warn("after sleep 1  66666666666666666666666\n");

    // Create player1
    //Causes error: expected type '?fn(usize) void', found '(bound fn(usize) void)'
    //var player1 = Player.initFull(thread1_context.doneFn, @ptrToInt(&thread1_context));
    var player1 = Player.initFull(threadDoneFn, @ptrToInt(&thread1_context));
    player1.body.max_hits = max_hits;
    assert(player1.body.hits == 0);
    warn("add player1\n");
    thread1_context.player = &player1;
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

    warn("call wait thread0\n");
    thread0.wait();
    warn("call wait thread1\n");
    thread1.wait();
    warn("aftr wait thread1\n");

    // Validate players hit the ball the expected number of times.
    assert(player0.body.hits > 0);
    assert(player1.body.hits > 0);
    assert(player1.body.last_ball_hits > 0);
    assert(player0.body.hits + player1.body.hits == player1.body.last_ball_hits);
}
