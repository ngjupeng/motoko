---
sidebar_position: 1
---

# What is orthogonal persistence?

Orthogonal persistence is the ability to for a program to automatically preserve its state across transactions and canister upgrades without requiring manual intervention. This means that data persists seamlessly, without the need for a database, stable memory APIs, or specialized stable data structures.

Although Motoko’s persistence model is complex under the hood, it’s designed to be both safe and efficient. By simply using the `persistent` (actors) or `stable` (data structures) keyword, developers can mark pieces of their program as persistent. This abstraction significantly reduces the risk of data loss or corruption during upgrades.

In contrast, other canister development languages like Rust require explicit handling of persistence. Developers must manually manage stable memory and use specialized data structures to ensure data survives upgrades. These languages lack orthogonal persistence, and may rearrange memory unpredictably during recompilation or runtime, making safe persistence more error-prone and labor-intensive.

Motoko features two implementations for orthogonal persistence:

* [Enhanced orthogonal persistence](https://internetcomputer.org/docs/motoko/orthogonal-persistence/enhanced) provides very fast upgrades, scaling independently of the heap size. This is realized by retaining the entire Wasm main memory on an upgrade and simply performing a type-driven upgrade safety check. By using 64-bit address space, it is designed to scale beyond 4 GiB and in the future, offer the same capacity like stable memory.

* [Classical orthogonal persistence](https://internetcomputer.org/docs/motoko/orthogonal-persistence/classical) is the old implementation of orthogonal persistence that is superseded by enhanced orthogonal persistence. On an upgrade, the runtime system first serializes the persistent data to stable memory and then deserializes it back again to main memory. While this is both inefficient and unscalable, it exhibits problems on shared immutable data (potentially leading to state explosion), deep structures (call stack overflow) and larger heaps (the implementation limits the stable data to at most 2 GiB).

:::info

Since version 0.15.0, the `moc` compiler enables enhanced orthogonal persistence by default.
Classical orthogonal persistence, the default compilation mode in previous versions has been deprecated and can only be re-enabled with a compiler flag (`--legacy-persistence`).

Although it is possible to upgrade a canister compiled with classical persistence to one compiled with enhanced-orthogonal-persistence, downgrades from enhanced to classical are *not* supported.

:::