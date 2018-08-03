# Zig Actor

Create an Actor Model sub-system for zig. This is
based on the zig-simple-actor code and uses the
"interface" model to allow generic Actors and
generic Messages.

## Test
```bash
$ zig test test.zig
Test 1/1 Actor...call threadSpawn
thread0_context.name len=32 name=thread0
call wait
threadDispatcher: thread0
call after wait
OK
All tests passed.
```

## Clean
Remove `zig-cache/` directory
```bash
$ rm -rf ./zig-cache/
```
