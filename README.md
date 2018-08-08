# Zig Actor

Create an Actor Model sub-system for zig. This is
based on the zig-simple-actor code and uses the
"interface" model to allow generic Actors and
generic Messages.

Minimally functional at this point.

## Test
```bash
$ zig test test.zig
Test 1/4 Actor...ActorDispatcher.init: ActorDispatcher(5)@7ffc1adb7970:&signalContext=u32@7ffc1adb7998
ActorDispatcher.add: ActorDispatcher(5)@7ffc1adb7970:&signalContext=u32@7ffc1adb7998
ActorDispatcher.signalFn: call wake u32@7ffc1adb7998
ActorDispatcher.broadcastLoop: ActorDispatcher(5)@7ffc1adb7970:&signalContext=u32@7ffc1adb7998
call threadSpawn
thread0_context.name len=32 name=thread0
call wait
threadDispatcher: thread0
call after wait
OK
Test 2/4 MessageQueue.multi-threaded...putters are done, signal getter context.puts_done=1
startGetter: puts_done=1
OK
Test 3/4 MessageQueue.single-threaded...OK
Test 4/4 Futex...
test Futex:+ gCounter=0
test Futex: gCounter=2000000
test Futex:- gCounter=2000000
OK
All tests passed.
```

## Clean
Remove `zig-cache/` directory
```bash
$ rm -rf ./zig-cache/
```
