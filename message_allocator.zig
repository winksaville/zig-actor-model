/// MessageAllocator
const messageNs = @import("message.zig");
const Message = messageNs.Message;
const MessageHeader = messageNs.MessageHeader;

const messageQueueNs = @import("message_queue.zig");
const MessageQueue = messageQueueNs.MessageQueue;
const SignalContext = messageQueueNs.SignalContext;

//const futex_wait = @import("futex.zig").futex_wait;
//const futex_wake = @import("futex.zig").futex_wake;

const std = @import("std");
const assert = std.debug.assert;
const warn = std.debug.warn;
const mem = std.mem;
const Allocator = mem.Allocator;
const DirectAllocator = std.heap.DirectAllocator;

//const AtomicOrder = builtin.AtomicOrder;
//const AtomicRmwOp = builtin.AtomicRmwOp;

/// A Message allocator messages which are preallocated and stored on
/// a MessageQueue which is a multi-producer single-consumer queue.
///
/// We assume one thread will be using get but many threads can use
/// put to return the messages.
///
/// TODO: 0) Not sure the signalFn is the best way to handle being
///       notified that there are now messages available. Although
///       I think having some way of knowing that could be useful.
///
///       1) For performance using a Stack rather than a Queue would be
///       better as reusing a message that's recently been use could
///       have better performance.
///
///       2) Using an array rather than a link list would probably
///       improve performance.
pub fn MessageAllocator() type {

    return struct {
        pub const Self = this;

        direct_allocator: DirectAllocator,
        allocator: Allocator,
        signalContext: SignalContext,
        queue: MessageQueue(),

        // Make sure message size is a multiple alignment
        const alignment: u29 = 64;
        msg_count: usize,
        max_msg_size: usize,
        buffer: [] align(alignment) u8,

        pub fn init(pSelf: *Self, msg_count: usize, max_msg_body_size: usize) !void {
            if (msg_count == 0) return error.MsgCountMustBeGreaterThanZero;

            pSelf.direct_allocator = DirectAllocator.init();
            pSelf.allocator = pSelf.direct_allocator.allocator;
            pSelf.signalContext = 0;
            pSelf.queue = MessageQueue().init(signalFn, &pSelf.signalContext);

            // Allocate the buffer
            pSelf.msg_count = msg_count;
            pSelf.max_msg_size =
                ((@sizeOf(MessageHeader) + max_msg_body_size + alignment - 1) / alignment) * alignment;
            pSelf.buffer = try pSelf.allocator.alignedAlloc(u8, alignment, msg_count * pSelf.max_msg_size);

            // Carve up the buffer placing the messages on the queue
            var i: usize = 0;
            while (i < msg_count) {
                assert(@offsetOf(Message(packed struct {}), "header") == 0);
                var pMh = @ptrCast(*MessageHeader, &pSelf.buffer[i * pSelf.max_msg_size]);
                pMh.initEmpty();
                pMh.cmd = 0xDeadbeef;
                pSelf.put(pMh);
                i += 1;
            }
            //warn("MessageAllocator.init: pSelf={*}\n", pSelf);
        }

        pub fn deinit(pSelf: *Self) void {
            // TODO: On a test build, at lease, detect that all
            // messages have been returned before deallocating.

            //warn("MessageAllocator.deinit: pSelf={*}\n", pSelf);
            pSelf.direct_allocator.deinit();
        }

        /// Put the message back, ignoring null pointers
        pub fn put(pSelf: *Self, pMessageHeader: ?*MessageHeader) void {
            if (pMessageHeader) |pMh| {
                pSelf.queue.put(pMh);
            }
        }

        /// Get a message initializing only MessageType.allocator
        pub fn get(pSelf: *Self, comptime MessageType: type) ?*MessageType {
            //warn("MessageAllocator.get: sizeOf(MessageType)={} max_msg_size={}\n",
            //            usize(@sizeOf(MessageType)), pSelf.max_msg_size);
            if (@sizeOf(MessageType) > pSelf.max_msg_size) return null;
            var pMh: *MessageHeader = pSelf.queue.get() orelse return null;
            pMh.pAllocator = pSelf;
            return MessageType.getMessagePtr(pMh);
        }

        // Maybe we want this signal to go to the entity (Actor) that owns
        // this allocator so they do what need to do directly.
        fn signalFn(pSignalContext: *SignalContext) void {
            //warn("MessageAllocator.signalFn: {*}\n", pSignalContext);
            //futex_wake(pSignalContext, 1);
        }
    };
}


test "MessageAllocator.1" {
    var direct_allocator = DirectAllocator.init();
    defer direct_allocator.deinit();
    var allocator = direct_allocator.allocator;

    // Test that we know how to use allocator.createOne
    var pU32: *u32 = try allocator.createOne(u32);
    defer allocator.destroy(pU32);
    pU32.* = 123;
    assert(pU32.* == 123);

    // Create MyMa on the stack
    var myMa1: MessageAllocator() = undefined;
    try myMa1.init(2, 2048);
    defer myMa1.deinit();

    // Create a Msg type and an array of messages
    const Msg = Message(packed struct {
        const Self = this;

        buffer: [2048]u8,

        pub fn init(pSelf: *Self) void {
            mem.set(u8, pSelf.buffer[0..], 123);
        }
    });
    var msgs: [2] *Msg = undefined;

    // Get first 2 messages and be sure there is no overlap.
    // We're assuming msgs[0] is adjacent and before msgs[1]
    // which is the case now, but may not be in the future,
    // for instance is we change to use a stack rather than
    // a queue.
    msgs[0] = myMa1.get(Msg) orelse return error.badmsgs0;
    msgs[1] = myMa1.get(Msg) orelse return error.badmsgs1;
    assert(@ptrToInt(&msgs[0].body.buffer[2047]) < @ptrToInt(&msgs[1]));
    assert(myMa1.get(Msg) == null);

    msgs[0].init(1);
    assert(msgs[0].body.buffer[0] == 123);

    // Put them back via header.allocator
    if (msgs[0].header.pAllocator) |pA| pA.put(&msgs[0].header) else return error.HeaderAllocatorNotInitialized;
    if (msgs[1].header.pAllocator) |pA| pA.put(&msgs[1].header) else return error.HeaderAllocatorNotInitialized;

    // Verify we can get them again and this time we'll put them back directly
    msgs[0] = myMa1.get(Msg) orelse return error.badmsgs0;
    msgs[1] = myMa1.get(Msg) orelse return error.badmsgs1;
    assert(myMa1.get(Msg) == null);
    myMa1.put(&msgs[0].header);
    myMa1.put(&msgs[1].header);

    // Create MyMa using allocator
    var myMa2 = try allocator.createOne(MessageAllocator());
    defer allocator.destroy(myMa2);
    try myMa2.init(10, 204);
    defer myMa2.deinit();
}
