// Create a Message that supports arbitrary data
// and can be passed between entities via a Queue.

const ActorInterface = @import("actor.zig").ActorInterface;
const MessageAllocator = @import("message_allocator.zig").MessageAllocator;

const messageQueueNs = @import("message_queue.zig");
const MessageQueue = messageQueueNs.MessageQueue;
const SignalContext = messageQueueNs.SignalContext;

const std = @import("std");
const assert = std.debug.assert;
const warn = std.debug.warn;

pub fn Message(comptime BodyType: type) type {
    return packed struct {
        const Self = @This();

        pub header: MessageHeader, // Must be first field
        pub body: BodyType,

        /// Initialize header.cmd and BodyType.init,
        /// NOTE: Header is NOT initialized!!!!
        pub fn init(pSelf: *Self, cmd: u64) void {
            // TODO: I'm unable to make this assert it when moving header
            //warn("{*}.init({})\n", pSelf, cmd);
            assert(@byteOffsetOf(Message(packed struct {}), "header") == 0);
            pSelf.header.cmd = cmd;
            BodyType.init(&pSelf.body);
        }

        /// Initialize the header to empty
        pub fn initHeaderEmpty(pSelf: *Self) void {
            pSelf.header.initEmpty();
        }

        /// Initialize the body
        pub fn initBody(pSelf: *Self) void {
            BodyType.init(&pSelf.body);
        }

        /// Send this message to destination queue
        pub fn send(pSelf: *Self) !void {
            if (pSelf.getDstQueue()) |pQ| pQ.put(&pSelf.header) else return error.NoQueue;
        }

        /// Get the destination queue
        pub fn getDstQueue(pSelf: *const Self) ?*MessageQueue() {
            return pSelf.header.pDstActor.?.pQueue;
        }

        /// Return a pointer to the Message this MessageHeader is a member of.
        pub fn getMessagePtr(header: *MessageHeader) *Self {
            return @fieldParentPtr(Self, "header", header);
        }

        /// Format the message to a byte array using the output fn
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
    const Self = @This();

    // TODO: Rename as pXxxx
    pub pNext: ?*MessageHeader,
    pub pAllocator: ?*MessageAllocator(),
    pub pSrcActor: ?*ActorInterface,
    pub pDstActor: ?*ActorInterface,
    pub cmd: u64,

    pub fn init(
        pSelf: *Self,
        pAllocator: ?*MessageAllocator(),
        pSrcActor: ?*ActorInterface,
        pDstActor: ?*ActorInterface,
        cmd: u64,
    ) void {
        pSelf.pNext = null;
        pSelf.pAllocator = pAllocator;
        pSelf.pSrcActor = pSrcActor;
        pSelf.pDstActor = pDstActor;
        pSelf.cmd = cmd;
    }

    pub fn initEmpty(pSelf: *Self) void {
        pSelf.pNext = null;
        pSelf.pAllocator = null;
        pSelf.pSrcActor = null;
        pSelf.pDstActor = null;
        pSelf.cmd = 0;
    }

    pub fn initSwap(pSelf: *Self, pSrcMh: *MessageHeader) void {
        pSelf.pDstActor = pSrcMh.pSrcActor;
        pSelf.pSrcActor = pSrcMh.pDstActor;
    }

    pub fn format(
        pSelf: *const Self,
        comptime fmt: []const u8,
        context: var,
        comptime FmtError: type,
        output: fn (@typeOf(context), []const u8) FmtError!void
    ) FmtError!void {
        var pDstQueue: ?*MessageQueue() = null;
        var pDstSigCtx: *SignalContext = @intToPtr(*SignalContext, 0);
        if (pSelf.pDstActor) |pAi| {
            if (pAi.pQueue) |pQ| {
                pDstQueue = pQ;
                if (pQ.pSignalContext) |pCtx| {
                    pDstSigCtx = pCtx;
                }
            }
        }
        var pSrcQueue: ?*MessageQueue() = null;
        var pSrcSigCtx: *SignalContext = @intToPtr(*SignalContext, 0);
        if (pSelf.pSrcActor) |pAi| {
            if (pAi.pQueue) |pQ| {
                pSrcQueue = pQ;
                if (pQ.pSignalContext) |pCtx| {
                    pSrcSigCtx = pCtx;
                }
            }
        }

        try std.fmt.format(context, FmtError, output, "pSrcActor={*}:{*}:{} pDstActor={*}:{*}:{} cmd={}, ",
                pSelf.pSrcActor, pSrcQueue, pSrcSigCtx, pSelf.pDstActor, pDstQueue, pDstSigCtx, pSelf.cmd);
    }
};
