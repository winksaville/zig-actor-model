// Create a Message that supports arbitrary data
// and can be passed between entities via a Queue.

const ActorInterface = @import("actor.zig").ActorInterface;
const MessageAllocator = @import("message_allocator.zig").MessageAllocator;
const MessageQueue = @import("message_queue.zig").MessageQueue;

const std = @import("std");
const assert = std.debug.assert;
const warn = std.debug.warn;

pub fn Message(comptime BodyType: type) type {
    return packed struct {
        const Self = this;

        pub header: MessageHeader, // Must be first field
        pub body: BodyType,

        /// Initialize header.cmd and BodyType.init
        pub fn init(pSelf: *Self, cmd: u64) void {
            // TODO: I'm unable to make this assert it when moving header
            //warn("{*}.init({})\n", pSelf, cmd);
            assert(@offsetOf(Message(packed struct {}), "header") == 0);
            pSelf.header.cmd = cmd;
            BodyType.init(&pSelf.body);
        }

        pub fn initHeaderEmpty(pSelf: *Self) void {
            pSelf.header.initEmpty();
        }

        pub fn initBody(pSelf: *Self) void {
            BodyType.init(&pSelf.body);
        }


        /// Return a pointer to the Message this MessageHeader is a member of.
        pub fn getMessagePtr(header: *MessageHeader) *Self {
            return @fieldParentPtr(Self, "header", header);
        }

        pub fn format(
            pSelf: *const Self,
            comptime fmt: []const u8,
            context: var,
            comptime FmtError: type,
            output: fn (@typeOf(context), []const u8) FmtError!void
        ) FmtError!void {
            try std.fmt.format(context, FmtError, output, "{{");
            try pSelf.header.format("", context, FmtError, output);
            try std.fmt.format(context, FmtError, output, "body={{");
            try BodyType.format(&pSelf.body, fmt, context, FmtError, output);
            try std.fmt.format(context, FmtError, output, "}},");
            try std.fmt.format(context, FmtError, output, "}}");
        }
    };
}

pub const MessageHeader = packed struct {
    const Self = this;

    // TODO: Rename as pXxxx
    pub pNext: ?*MessageHeader,
    pub pAllocator: ?*MessageAllocator(),
    pub pSrcQueue: ?*MessageQueue(),
    pub pSrcActor: ?*ActorInterface,
    pub pDstQueue: ?*MessageQueue(),
    pub pDstActor: ?*ActorInterface,
    pub cmd: u64,

    pub fn init(
        pSelf: *Self,
        pAllocator: ?*MessageAllocator(),
        pSrcQueue: ?*MessageQueue(),
        pSrcActor: ?*ActorInterface,
        pDstQueue: ?*MessageQueue(),
        pDstActor: ?*ActorInterface,
        cmd: u64,
    ) void {
        pSelf.pNext = null;
        pSelf.pAllocator = pAllocator;
        pSelf.pSrcQueue = pSrcQueue;
        pSelf.pSrcActor = pSrcActor;
        pSelf.pDstQueue = pDstQueue;
        pSelf.pDstActor = pDstActor;
        pSelf.cmd = cmd;
    }

    pub fn initEmpty(pSelf: *Self) void {
        pSelf.pNext = null;
        pSelf.pAllocator = null;
        pSelf.pSrcQueue = null;
        pSelf.pSrcActor = null;
        pSelf.pDstQueue = null;
        pSelf.pDstActor = null;
        pSelf.cmd = 0;
    }

    pub fn initSwap(pSelf: *Self, pSrcMh: *MessageHeader) void {
        pSelf.pDstActor = pSrcMh.pSrcActor;
        pSelf.pDstQueue = pSrcMh.pSrcQueue;
        pSelf.pSrcActor = pSrcMh.pDstActor;
        pSelf.pSrcQueue = pSrcMh.pDstQueue;
    }

    pub fn format(
        pSelf: *const Self,
        comptime fmt: []const u8,
        context: var,
        comptime FmtError: type,
        output: fn (@typeOf(context), []const u8) FmtError!void
    ) FmtError!void {
        try std.fmt.format(context, FmtError, output, "pSrcQueue={*} pSrcActor{*} pDstQueue={*} pDstActor{*} cmd={}, ",
                pSelf.pSrcQueue, pSelf.pSrcActor, pSelf.pDstQueue, pSelf.pDstActor, pSelf.cmd);
    }
};
