# SynchroBeast

Synchronise the start of two programs running on two different {Micro/Nano}Beasts.

They're connected via a simple 3 wire interface:

![Beast sync cable](images/wire.png)

In a pinch you could probably forego the resistors and just use 3 wires, and it should
still work.


## Build it 

### Hardware 

![BeastSync dongle](images/board.jpg)

The BeastSync dongle is trivially easy to build! A couple of 1k current limiting resistors,
and two weak 10k pull-downs, and some connectors.

### Software

You need [sjasmplus](). Edit the `Makefile` to point to it then type: 

```
make
```

This should generate `SYNC.COM` that you can copy to the machines you want to 
synchronise. It's one binary for nanobeast/microbeast, whether "leader" or
"follower".

## Usage 

If you've got a command you want to run on both machines, prefix it with `sync` and 
some mode flags:

```
SYNC <flags> <prog>[.ext] [args...]
```

Where:

flags (any order, any case, other letters ignored):
  - **M**  MicroBeast (Z84C20 PIO)
  - **N**  NanoBeast (CPLD-based PIO)
  - **L**  leader (sends the heartbeat and the START pulse)
  - **F**  follower (monitors heartbeat and START pulse)

**\<prog\>** defaults to .COM. Everything after it becomes the program's
command tail at 0x0080, and the first two words are parsed into the
default FCBs at 0x005C/0x006C, just as the CCP would have done. (In fact
this is the bulk of the code below, the actual syncing is pretty trivial!)


Once you've run that on one machine, run the equivalent command on the other 
machine. One machine must be "leader" and the other must be "follower".

*\<prog\>* must exist on both machines, there's no file transfer here. 

Obviously you can use a different *<prog>* on Machine A than Machine B. Their
starts will still be synchronised. 

## Pitfalls 

`sync.com` copies itself into high memory, and runs there as an overlay 
on top of \<prog\>. If \<prog\> is huge, there might not be enough space
left for `sync.com`, in which case it will print an error and bail.

## Example 

On machine A, a MicroBeast:

```
sync ML phaserf
```

The MicroBeast is the leader, it will wait for another machine to sync.

On Machine B, a NanoBeast:

```
sync NF phaserf
```

The NanoBeast is the follower. It will sync with the master, then both 
should begin playing in unison. The sync handshake takes around 30ms, and the 
latency between the two should be +/- 20 T-states, or about 2us.

It doesn't matter which one starts first: you can start the follower after 
the leader, if you like.

## How it works 

![BeastSync scope trace](images/scope.jpg)

The "leader" sends out a square wave on PA0 at a particular period, and listens for 
it coming back on PA1, with the same period. Once it receives 8 such confirmations, 
it sends a longer START pulse, and then jumps to the start of the wrapped program \<prog\>.

The "follower" just copies any activity it sees on PA1 to PA0. It measures how long the 
pulses are though, and as soon as it sees one that looks like a START pulse it starts 
its own wrapped \<prog\>.

It's a bit like a spectrum tape loading pilot tone, but with another computer instead
of a cassette recorder (and there's no subsequent data transfer).
