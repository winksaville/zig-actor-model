// Actor manager

const ActorInterface = @import("actor.zig").ActorInterface;
const MessageHeader = @import("message.zig").MessageHeader;
const AtomicOrder = builtin.AtomicOrder;
const AtomicRmwOp = builtin.AtomicRmwOp;

const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const warn = std.debug.warn;
const Queue = std.atomic.Queue;

pub const ActorChannel = struct {
    pAi: *ActorInterface,
    queue: Queue(*MessageHeader),
    //actorType: type,
    //name: [64]u8,
}

/// Manage a set of actors
pub fn ActorManager(comptime maxActors: usize, comptime maxThreads: usize) type {
    return struct {
        const Self = this;

        lock: u8,

        const ThreadContext = struct {
            const Self = this;

            name_len: usize,
            name: [32]u8,
            pThread: *std.os.Thread,

            fn init(pSelf: *Self, name: [] const u8) void {
                // Set name_len and then copy with truncation
                pSelf.name_len = math.min(name.len, pSelf.name.len);
                mem.copy(u8, pSelf.name[0..pSelf.name_len], name[0..pSelf.name_len]);
            }

            fn threadDispatcher(pContext: *ThreadContext) void {
                warn("threadDispatcher: {}\n", pContext.name[0..pContext.name_len]);
            }
        };

        var thread0_context: ThreadContext = undefined;

        // Array of ActorChannels, associating an Actor instance and a queue.
        actors: [maxActors]ActorChannel,
        actors_count: usize,

        // Array of threads with one dispatcher per thread
        threads: [maxThreads]: ThreadContext,
        threads_count: usize,
        
        pub fn init() Self {
            return Self {
                .lock = 0,
                .actors = undefined,
                .actors_count = 0,
                .threads = undefined
                .threads_count = 0,
            };
        }

        pub fn add(
            pSelf: *Self,
            pAi: *ActorInterface,
            name: [] const u8,
            comptime T: type,
        ) !void {
            while (@atomicRmw(u8, pSelf.lock, AtomicRmwOp.Xchg, 1, AtomicOrder.SeqCst) != 0) {}
            defer assert(@atomicRmw(u8, pSelf.lock, AtomicRmwOp.Xchg, 0, AtomicOrder.SeqCst) == 1);

            if (pSelf.actors_count >= self.actors.len) return error.TooManyActors;
            pSelf.actors[self.actors_count]. = pAi;
            pSelf.actors_count += 1;
        }
    };
}

    warn("call threadSpawn\n");
    thread0_context.init("thread0");
    warn("thread0_context.name len={} name={}\n", thread0_context.name.len,
            thread0_context.name[0..thread0_context.name_len]);
    var thread_0 = try std.os.spawnThread(&thread0_context, threadDispatcher);
    warn("call wait\n");
    thread_0.wait();
    warn("call after wait\n");
