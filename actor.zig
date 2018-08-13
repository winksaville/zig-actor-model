const messageNs = @import("message.zig");
const MessageHeader = messageNs.MessageHeader;

const std = @import("std");
const warn = std.debug.warn;

/// ActorInterface is a member of all Actor's and
/// every Actor must implement processMessage who's
/// address is saved in this interface when an Actor
/// is initialized by calling Actor(BodyType).init().
///
/// There must also be a BodyType.init(*Actor(BodyType))
pub const ActorInterface = packed struct {
    // TODO: Add pQueue here so we don't need
    // both a ?*MessageQueue and ?*ActorInterface in
    // MessageHeader.
    //pQueue: ?*MessageQueue,

    pub processMessage: fn (actorInterface: *ActorInterface, msg: *MessageHeader) void,

    // An optional function supplied by the dispatcher whcih the
    // actor calls when it's complete. It will pass the
    // doneFn_handle as the parameter.
    pub doneFn: ?fn (doneFn_handle: usize) void,
    pub doneFn_handle: usize,
};

/// Actor that can process messages. Actors implement
/// processMessage in the BodyType passed to this Actor
/// Type Constructor.
pub fn Actor(comptime BodyType: type) type {
    return struct {
        const Self = this;

        pub interface: ActorInterface,
        pub body: BodyType,

        pub fn init() Self {
            return Self.initFull(null, 0);
        }

        pub fn initFull(doneFn: ?fn (doneFn_handle: usize) void, doneFn_handle: usize) Self {
            var self: Self = undefined;
            self.interface.processMessage = BodyType.processMessage;
            self.interface.doneFn = doneFn;
            self.interface.doneFn_handle = doneFn_handle;

            BodyType.init(&self);
            //warn("Actor.init: pAi={*} self={*} processMessage={x}\n",
            //    &self.interface, &self, @ptrToInt(self.interface.processMessage));
            return self;
        }

        /// Return a pointer to the Actor this interface is a member of.
        pub fn getActorPtr(pAi: *ActorInterface) *Self {
            return @fieldParentPtr(Self, "interface", pAi);
        }
    };
}

// Tests

const Message = messageNs.Message;
const mem = std.mem;

const assert = std.debug.assert;

const MyMsgBody = packed struct {
    const Self = this;
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

const MyActorBody = struct {
    const Self = this;

    count: u64,

    fn init(actor: *Actor(MyActorBody)) void {
        actor.body.count = 0;
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

test "Actor" {
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
}
