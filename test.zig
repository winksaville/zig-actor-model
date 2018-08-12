// Create a Message that supports arbitrary data
// and can be passed between entities via a Queue.

const actorNs = @import("actor.zig");
const Actor = actorNs.Actor;
const ActorInterface = actorNs.ActorInterface;

const msgNs = @import("message.zig");
const Message = msgNs.Message;
const MessageHeader = msgNs.MessageHeader;

const MessageAllocator = @import("message_allocator.zig").MessageAllocator;

const ActorDispatcher = @import("actor_dispatcher.zig").ActorDispatcher;

const std = @import("std");
const bufPrint = std.fmt.bufPrint;
const assert = std.debug.assert;
const warn = std.debug.warn;
const mem = std.mem;
const math = std.math;
const Queue = std.atomic.Queue;

const Ball = packed struct {
    const Self = this;

    hits: u64,

    fn init(pSelf: *Self) void {
        pSelf.hits = 0;
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
        PlayerBody.abc();
    }

    fn abc() void {
        warn("PlayerBody.abc\n");
    }

    fn hitBall(pSelf: *Actor(PlayerBody), pMsg: *Message(Ball)) !void {
        var pDstQ = pMsg.header.pDstQueue orelse return error.NoDstQueue;
        var pResponse = pSelf.body.allocator.get(Message(Ball)) orelse return; // error.NoMessages;
        pResponse.init(1);
        pResponse.header.initSwap(&pMsg.header);
        pResponse.body.hits = pMsg.body.hits + 1;
        pDstQ.put(&pResponse.header);
    }

    pub fn processMessage(pActorInterface: *ActorInterface, pMsgHeader: *MessageHeader) void {
        var pSelf: *Actor(PlayerBody) = Actor(PlayerBody).getActorPtr(pActorInterface);
        var pMsg = Message(Ball).getMessagePtr(pMsgHeader);

        //warn("{*}.processMessage pMsgHeader={*} cmd={}\n", pSelf, pMsgHeader, pMsgHeader.cmd);
        switch(pMsg.header.cmd) {
            0 => {
                //warn("PlayerBody.processMessage: cmd 0 start\n");
                PlayerBody.hitBall(pSelf, pMsg) catch |err| warn("error hitBall={}\n", err);
            },
            1 => {
                //warn("PlayerBody.processMessage: cmd 1 ball hit to us\n");
                pSelf.body.hits += 1;
                pSelf.body.last_ball_hits = pMsg.body.hits;
                if (pSelf.body.hits <= pSelf.body.max_hits) {
                    PlayerBody.hitBall(pSelf, pMsg) catch |err| warn("error hitBall={}\n", err);
                }
            },
            else => {
                // Ignore unknown commands
                warn("{*} unknown cmd={}\n", pSelf, pMsg.header.cmd);
            },
        }

        // TODO: Should process message be responsible for returning message?
        if (pMsg.header.pAllocator) |pAllocator| pAllocator.put(pMsgHeader);
    }
};

//const ThreadContext = struct {
//    const Self = this;
//
//    name_len: usize,
//    name: [32]u8,
//
//    pub fn init(pSelf: *Self, name: [] const u8) void {
//        // Set name_len and then copy with truncation
//        pSelf.name_len = math.min(name.len, pSelf.name.len);
//        mem.copy(u8, pSelf.name[0..pSelf.name_len], name[0..pSelf.name_len]);
//    }
//};
//
//var thread0_context: ThreadContext = undefined;
//
//fn threadDispatcher(context: *ThreadContext) void {
//    warn("threadDispatcher: {}\n", context.name[0..context.name_len]);
//}

test "test.Actor" {
    // Create Dispatcher
    const Dispatcher = ActorDispatcher(2);
    var dispatcher: Dispatcher = undefined;
    dispatcher.init();

    // Create a Player type
    const Player = Actor(PlayerBody);

    // Create player1
    var player1 = Player.init();
    player1.body.max_hits = 10;
    assert(player1.body.hits == 0);
    try dispatcher.add(&player1.interface);

    // Create player2
    var player2 = Player.init();
    player2.body.max_hits = 10;
    assert(player2.body.hits == 0);
    try dispatcher.add(&player2.interface);

    // Create a message to get things going
    var ballMsg: Message(Ball) = undefined;
    ballMsg.init(0);

    ballMsg.header.pAllocator = null;
    ballMsg.header.pDstActor = &player1.interface;
    ballMsg.header.pDstQueue = &dispatcher.queue; // Move to ActorInterface and init in dispatcher.add?
    ballMsg.header.pSrcActor = &player2.interface;
    ballMsg.header.pSrcQueue = &dispatcher.queue;

    ballMsg.initBody();

    assert(ballMsg.header.pDstQueue != null);
    ballMsg.header.pDstQueue.?.put(&ballMsg.header);
    dispatcher.loop();

    assert(player1.body.hits + player2.body.hits == player2.body.last_ball_hits);

    //warn("call threadSpawn\n");
    //thread0_context.init("thread0");
    //warn("thread0_context.name len={} name={}\n", thread0_context.name.len,
    //        thread0_context.name[0..thread0_context.name_len]);
    //var thread_0 = try std.os.spawnThread(&thread0_context, threadDispatcher);
    //warn("call wait\n");
    //thread_0.wait();
    //warn("call after wait\n");
}
