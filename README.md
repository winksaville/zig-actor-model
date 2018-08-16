# Zig Actor

Create an Actor Model sub-system for zig. This is
based on the zig-simple-actor code and uses the
"interface" model to allow generic Actors and
generic Messages.

Somewhat functional at this point.

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
## Notes
### Futex

On my desktop when mode is naive and its a debug build takes about 30 seconds:
```bash
$ zig test futex.zig
Test 1/1 Futex...
test Futex:+ gCounter=0 gProducerWaitCount=0 gConsumerWaitCount=0 gProducerWakeCount=0 gConsuerWakeCount=0
test Futex: time=28.671786
test Futex:- gCounter=20000000 gProducerWaitCount=6520118 gConsumerWaitCount=6521602 gProducerWakeCount=10000000 gConsuerWakeCount=10000000
OK
All tests passed.
```

if mode is !naive is about 10x faster at about 3 seconds.
```bash
$ zig test futex.zig
Test 1/1 Futex...test Futex:+ gCounter=0 gProducerWaitCount=0 gConsumerWaitCount=0 gProducerWakeCount=0 gConsuerWakeCount=0
test Futex: time=2.930429
test Futex:- gCounter=20000000 gProducerWaitCount=26 gConsumerWaitCount=10 gProducerWakeCount=143 gConsuerWakeCount=178
OK
All tests passed.
```

But with a --release-fast and mode is !naive it takes about 25 seconds:
```bash
$ zig test --release-fast futex.zig
Test 1/1 Futex...
test Futex:+ gCounter=0 gProducerWaitCount=0 gConsumerWaitCount=0 gProducerWakeCount=0 gConsuerWakeCount=0
test Futex: time=24.833821
test Futex:- gCounter=20000000 gProducerWaitCount=5804057 gConsumerWaitCount=5813210 gProducerWakeCount=9999938 gConsuerWakeCount=9999952
OK
All tests passed.
```

I looked at the assembler output with `objdump --source -d -M intel zig-cache/test > test.fast.asm` and
found the code at `<MainFuncs_linuxThreadMain>:`. In that routine we see both the producer code
followed by the consumer at `<MainFuncs_linuxThreadMain.21>:`. Comparing the output to `test.debug.asm`
it appears to me the compiler optimized away the "stall" loops. I saw similar times with --release-small (26s)
and --release-safe (28s).
