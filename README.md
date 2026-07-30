# zigvibe

A vibe-coding experiment: the same small web app — a users table with add and
delete, backed by SQLite and driven by [Datastar](https://data-star.dev) —
implemented once in each language.

- [`go/`](go/) — Go 1.26 implementation
  - [Templ](https://templ.guide) for templating.
  - [sqinn-go](https://github.com/cvilsmeier/sqinn-go) for SQLite.
  - [datastar-go](https://github.com/starfederation/datastar-go) Datastar server SDK.
- [`zig/`](zig/) — Zig 0.16 implementation
  - [zt](https://github.com/lalinsky/zt) for templating.
  - vendored [SQLite](https://sqlite.org) amalgamation for SQLite.
  - [datastar-zig](https://github.com/starfederation/datastar-zig) Datastar server SDK.

See each folder's README for build and run instructions.

## Benchmark

[`bench/`](bench/) compares the two implementations on the same workload. It builds and runs each server one at a time (never concurrently), drives HTTP load with [k6](https://k6.io), and reports RPS, latency percentiles, and the server process tree's CPU and memory; on Linux with `perf` it adds hardware counters (cycles, instructions, cache misses).

```sh
cd bench
./bench.sh              # default: GET /, 50 connections, 10s
./bench.sh -d 30s -c 100
```

Requires k6, jq, curl, awk, and python3, plus the Go and Zig toolchains. See [`bench/README.md`](bench/README.md) for flags and details.

## Zig2

This is a handwritten version that pulls in the exact same Sqlite code that zig uses, but then uses the datastar.zig app framework
to do all the app stuff.

This adds some nice logging, a built in pubsub message bus for CQRS, and gives a DX that is much closer to the Go code (I think)

Its somewhat faster than the Claude generated Zig code ... 

Swapped out the ZT template for ZTS, which should be a way lot faster than ZT. This probably contributes to the good benchmark results quite a bit.

Added an option for building with lalinsky's zio async coroutines ... bringing it more inline with the Go experience, and improving performance a little again.

Then added a cache option to cache the generated users table part of the HTML, so streaming requests dont need to re-scan the whole DB each time. You could
do the same on the Go and Zig versions too if you want.
