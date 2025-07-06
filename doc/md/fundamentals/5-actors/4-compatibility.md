---
sidebar_position: 4
---

# Verifying upgrade compatibility



When upgrading a canister, it is important to verify that the upgrade can proceed without:

-   Introducing an incompatible change in stable declarations.
-   Breaking clients due to a Candid interface change.

`dfx` checks these properties statically before attempting the upgrade.
Moreover, with [enhanced orthogonal persistence](orthogonal-persistence/enhanced.md), Motoko rejects incompatible changes of stable declarations.

## Upgrade example

The following is a simple example of how to declare a stateful counter:

``` motoko no-repl file=../../examples/count-v0.mo
```

Importantly, in this example, when the counter is upgraded, its state is lost.
This is because actor variables are by default `transient`, meaning they get reinitialized on an upgrade.
The above actor is equivalent to using the `transient` declaration:

``` motoko no-repl file=../../examples/count-v0transient.mo
```


To fix this, you can declare a `stable` variable that is retained across upgrades:


``` motoko no-repl file=../../examples/count-v1stable.mo
```

To make `stable` the default for all declarations and `transient` optional, you can prefix the actor declaration with the keyword `persistent`.

``` motoko no-repl file=../../examples/count-v1.mo
```

If the variable `state` were not declared `stable`, either explicitly or by applying `persistent` to the `actor` keyword, `state` would restart from `0` on upgrade.

## Evolving the stable declarations

Changing counter from `Nat` to `Int` is a compatible change in stable declarations. The counter value is retained during the upgrade.

``` motoko no-repl file=../../examples/count-v2.mo
```

## Stable type signatures

A stable type signature describes the stable content of a Motoko actor.
You can think of this as the interior interface of the actor, that it presents to its future upgrades.

For example, `v1`'s stable types:

``` motoko no-repl file=../../examples/count-v1.most
```

An upgrade from `v1` to `v2`'s stable types consumes a [`Nat`](https://internetcomputer.org/docs/motoko/base/Int.md) as an [`Int`](https://internetcomputer.org/docs/motoko/base/Nat.md), which is valid because `Nat <: Int`, that is,  `Nat` is a subtype of `Int`.

``` motoko no-repl file=../../examples/count-v2.most
```

## Evolving the Candid interface

In this extension of the interface, old clients remain satisfied, while new ones get extra features such as the `decrement` function and the `read` query in this example.

``` motoko no-repl file=../../examples/count-v3.mo
```

## Dual interface evolution

An upgrade is safe provided that both the Candid interface and stable type signatures remain compatible:
* Each stable variable must either be newly declared, or re-declared at a stable supertype of its old type. A stable supertype is any supertype that
  does not involve promotion to `Any` or dropping object fields.
* The Candid interface evolves to a subtype.

Consider the following four versions of the counter example:

Version `v0` with Candid interface `v0.did` and stable type interface `v0.most`:

``` candid file=../../examples/count-v0.did
```

``` motoko no-repl file=../../examples/count-v0.most
```

Version `v1` with Candid interface `v1.did` and stable type interface `v1.most`,

``` candid file=../../examples/count-v1.did
```

``` motoko no-repl file=../../examples/count-v1.most
```

Version `v2` with Candid interface `v2.did` and stable type interface `v2.most`,

``` candid file=../../examples/count-v2.did
```

``` motoko no-repl file=../../examples/count-v2.most
```

Version `v3` with Candid interface `v3.did` and stable type interface `v3.most`:

``` candid file=../../examples/count-v3.did
```

``` motoko no-repl file=../../examples/count-v3.most
```

## Incompatible upgrade

Let's take a look at another example where the counter's type is again changed, this time from [`Int`](https://internetcomputer.org/docs/motoko/base/Int.md) to [`Float`](https://internetcomputer.org/docs/motoko/base/Float.md):

``` motoko no-repl file=../../examples/count-v4.mo
```

This version is neither compatible to stable type declarations, nor to the Candid interface.
- Since `Int </: Float`, that is, `Int` is not a subtype of `Float`, the old type of `state`, `Int`, is not compatible with the new type, `Float`.
  This means that the old value of `state`, an integer, cannot be used to initialize the new `state` field that now requires a float.
- The change in the return type of `read` is also not safe.
  If the change were accepted, then existing clients of the `read` method, that still expect to receive integers, would suddenly start receiving incompatible floats.

With [enhanced orthogonal persistence](orthogonal-persistence/enhanced.md), Motoko actively rejects any upgrades that require type-incompatible state changes.

This is to guarantee that the stable state is always kept safe.

```
Error from Canister ...: Canister called `ic0.trap` with message: RTS error: Memory-incompatible program upgrade.
```

In addition to Motoko's runtime check, `dfx` raises a warning message for these incompatible changes, including the breaking Candid change.

Motoko tolerates Candid interface changes, since these are more likely to be intentional, breaking changes.

:::danger
Versions of Motoko using [classical orthogonal persistence](orthogonal-persistence/classical.md) will drop the state and reinitialize the counter with `0.0`, if the `dfx` warning is ignored.

For this reason, users should always heed any compatibility warnings issued by `dfx`.
:::



## Explicit migration

### Explicit migration using several upgrades
There is always a migration path to change structure of stable state, even if a direct type change is not compatible.

For this purpose, a user-instructed migration can be done in three steps:

1. Introduce new variables of the desired types, while keeping the old declarations.
2. Write logic to copy the state from the old variables to the new variables on upgrade.

    While the previous attempt of changing state from [`Int`](https://internetcomputer.org/docs/motoko/base/Int.md) to [`Nat`](https://internetcomputer.org/docs/motoko/base/Float.md) was invalid, you now can realize the desired change as follows:

``` motoko no-repl file=../../examples/count-v5.mo
```

To also keep the Candid interface, the `readFloat` has been added, while the old `read` is retired by keeping its declaration and raising a trap internally.

3. Drop the old declarations once all data has been migrated.

In versions of Motoko prior to 0.14.6, you could simply remove the old variable or keep it but change the type to `Any`, implying that the variable is no longer useful.

``` motoko no-repl file=../../examples/count-v6.mo
```

For added safety, since version 0.14.6 you can only discard data or promote it to a lossy supertype such as `Any`, using a migration function:

``` motoko no-repl file=../../examples/count-v6b.mo
```

### Explicit migration using a migration function

The previous approach of using several upgrades to migrate data is both tedious and
obscure, mingling production with migration code.

To ease data migration, Motoko now supports explicit migration using a separate data migration function.
The code for the migration function is self-contained and can be placed in its own file.

The migration function takes a record of stable fields as input and produces a record of stable fields as output.

The input fields extend or override the types of any stable fields in the actor's
stable signature.
The output fields must be declared in the actor's stable signature, and have types that can be consumed by the corresponding declaration in the stable signature.

* All values for the input fields must
be present and of compatible type in the old actor, otherwise the
upgrade traps and rolls back.
* The fields output by the migration
function determine the values of the corresponding stable variables in the
new actor.
* All other stable variables of the actor, i.e. those neither consumed nor
produced by the migration function are initialized in the usual way,
either by transfer from the upgraded actor, if declared in that actor, or, if newly declared,
by running the initialization expression in the field's declaration.
* The migration function is only executed on an upgrade and ignored on a fresh installation of the actor in an empty canister.

The migration function, when required, is declared
using a parenthetical expression immediately preceding the actor or actor class declaration, for example:

``` motoko no-repl file=../../examples/count-v7.mo
```

The syntax employs Motoko's new parenthetical expressions to modify ugrade behaviour.
Other parenthetical expressions of similar form, but with different field names and types, are used to modify other aspects of Motoko's execution.

You can read this as a directive to apply the indicated `migration` function
just before upgrade.

Employing a migration function offers another advantage: it lets you re-use the name of an
existing field, even when its type has changed:

``` motoko no-repl file=../../examples/count-v8.mo
```

Here, the migration code is in a separate library:

``` motoko no-repl file=../../examples/Migration.mo
```

The migration function can be selective and only consume or produce a subset of the old and new stable variables. Other stable variables can be declared as usual.

For example, here, with the same migration function, you can also declare a new stable variable, `lastModified` that records the time of the last update,
without having to mention that field in the migration function:

``` motoko no-repl file=../../examples/count-v9.mo
```

The stable signature of an actor with a migration function now consists of two ordinary stable signatures, the pre-signature (before the upgrade), and the post-signature (after the upgrade).


For example, this is the combined signature of the previous example:

``` motoko no-repl file=../../examples/count-v9.most
```

The second signature is determined solely by the actor's stable variable declarations.
The first signature contains the field declarations from the migration function's input, together with any distinctly named stable variables declared in the actor.

For compatibility, when performing an upgrade, the (post) signature of the old code must be compatible with the (pre) signature of the new code.

The migration function can be deleted or adjusted on the next upgrade.

## Upgrade tooling

`dfx` incorporates an upgrade check. For this purpose, it uses the Motoko compiler (`moc`) that supports:

-   `moc --stable-types …​`: Emits stable types to a `.most` file.

-   `moc --stable-compatible <pre> <post>`: Checks two `.most` files for upgrade compatibility.

Motoko embeds `.did` and `.most` files as Wasm custom sections for use by `dfx` or other tools.

To upgrade e.g. from `cur.wasm` to `nxt.wasm`, `dfx` checks that both the Candid interface and stable variables are compatible:

```
didc check nxt.did cur.did  // nxt <: cur
moc --stable-compatible cur.most nxt.most  // cur <<: nxt
```

Using the versions above, the upgrade from `v3` to `v4` fails this check:

```
> moc --stable-compatible v3.most v4.most
(unknown location): Compatibility error [M0170], stable variable state of previous type
  var Int
cannot be consumed at new type
  var Float
```

With [enhanced orthogonal persistence](/docs/motoko/fundamentals/actors/orthogonal-persistence/enhanced), compatibility errors of stable variables are always detected in the runtime system and if failing, the upgrade is safely rolled back.

:::danger
With [classical orthogonal persistence](/docs/motoko/fundamentals/actors/orthogonal-persistence/classical), however, an upgrade attempt from `v2.wasm` to `v3.wasm` is unpredictable and may lead to partial or complete data loss if the `dfx` warning is ignored.
:::

## Adding record fields

A common, real-world example of an incompatible upgrade can be found [on the forum](https://forum.dfinity.org/t/questions-about-data-structures-and-migrations/822/12?u=claudio/).

In that example, a user was attempting to add a field to the record payload of an array, by upgrading from stable type interface:

``` motoko no-repl file=../../examples/Card-v0.mo
```

to *incompatible* stable type interface:

``` motoko no-repl file=../../examples/Card-v1.mo
```

### Problem

When trying this upgrade, `dfx` issues the following warning:

```
Stable interface compatibility check issued an ERROR for canister ...
Upgrade will either FAIL or LOSE some stable variable data.

(unknown location): Compatibility error [M0170], stable variable map of previous type
  var [(Nat32, Card)]
cannot be consumed at new type
  var [(Nat32, Card__1)]

Do you want to proceed? yes/No
```
It is recommended not to continue, as you will lose the state in older versions of Motoko that use [classical orthogonal persistence](orthogonal-persistence/classical.md).
Upgrading with [enhanced orthogonal persistence](orthogonal-persistence/enhanced.md) will trap and roll back, keeping the old state.

Adding a new record field to the type of existing stable variable is not supported. The reason is simple: the upgrade would need to supply values for the new field out of thin air. In this example, the upgrade would need to conjure up some value for the `description` field of every existing `card` in `map`. Moreover, allowing adding optional fields is also a problem, as a record can be shared from various variables with different static types, some of them already declaring the added field or adding a same-named optional field with a potentially different type (and/or different semantics).

To resolve this issue, some form of  [explicit data migration](#explicit-migration) is needed.


There are two solutions: using a sequence of simple upgrades, or the second, recommended solution, that uses a single upgrade with a migration function.

### Solution 1: Using two plain upgrades

1. You must keep the old variable `map` with the same structural type. However, you are allowed to change type alias name (`Card` to `OldCard`).
2. You can introduce a new variable `newMap` and copy the old state to the new one, initializing the new field as needed.
3. Then, upgrade to this new version.

``` motoko no-repl file=../../examples/Card-v1a.mo
```

4. **After** you have successfully upgraded to this new version, you can upgrade once more to a version, that drops the old `map`.


``` motoko no-repl file=../../examples/Card-v1b.mo
```

`dfx` will issue a warning that `map` will be dropped.

Make sure you have previously migrated the old state to `newMap` before applying this final reduced version.

```
Stable interface compatibility check issued a WARNING for canister ...
(unknown location): warning [M0169], stable variable map of previous type
  var [(Nat32, OldCard)]
 will be discarded. This may cause data loss. Are you sure?
```

### Solution 2: Using a migration function and single upgrade

Instead of the previous two step solution, you can upgrade in one step using a migration function.

1. Define a migration module and function that transforms the old stable variable, at its current type, into the new stable variable at its new type.


``` motoko no-repl file=../../examples/CardMigration.mo
```

2. Specify the migration function as the migration expression of your actor declaration:


``` motoko no-repl file=../../examples/Card-v1c.mo
```

**After** you have successfully upgraded to this new version, you can also upgrade once more to a version that drops the migration code.


``` motoko no-repl file=../../examples/Card-v1d.mo
```

However, removing or adjusting the migration code can also be delayed to the next, proper upgrade that fixes bugs or extends functionality.

Note that with this solution, there is no need to rename `map` to `newMap` and the migration code is nicely isolated from the main code.

