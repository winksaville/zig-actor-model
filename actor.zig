const MessageHeader = @import("message.zig").MessageHeader;

const std = @import("std");
const warn = std.debug.warn;

/// ActorInterface is a member of all Actor's and
/// every Actor must implement processMessage who's
/// address is saved in this interface when an Actor
/// is initialized by calling Actor(BodyType).init().
///
/// There must also be a BodyType.init(*Actor(BodyType))
pub const ActorInterface = packed struct {
    pub processMessage: fn (actorInterface: *ActorInterface, msg: *MessageHeader) void,
};

/// Actor that can process messages. Actors implement
/// processMessage in the BodyType passed to this Actor
/// Type Constructor.
pub fn Actor(comptime BodyType: type) type {
    return packed struct {
        const Self = this;

        pub interface: ActorInterface,
        pub body: BodyType,

        pub fn init() Self {
            var self: Self = undefined;
            self.interface.processMessage = BodyType.processMessage;
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

