---
sidebar_position: 1
---

# Primitive types

Motoko provides several primitive types that form the foundation of all computations. These include numeric types, characters and text, booleans, and floating-point numbers.

The primitive types are supported by a large set of familiar built-in operators such as `+`, `-` and so on.

More esoteric functions, not supported by dedicated operators, can be found in the corresponding libraries.

For example, the library function `Int.toText: Int -> Text`, declared in base package `Int`, returns the textual representation of its argument.

```motoko name=int
import Int "mo:base/Int";
Int.toText(0); // returns "0"
```

## Numeric types

Motoko supports both signed integers and unsigned naturals. Signed numbers can represent all numbers, positive and negative, while unsigned integers can only represent 0 and positive numbers. Natural numbers are unsigned integers.

- Signed integers: [`Int`](https://internetcomputer.org/docs/motoko/base/Int), [`Int8`](https://internetcomputer.org/docs/motoko/base/Int8), [`Int16`](https://internetcomputer.org/docs/motoko/base/Int16), [`Int32`](https://internetcomputer.org/docs/motoko/base/Int32), [`Int64`](https://internetcomputer.org/docs/motoko/base/Int64)
- Unsigned naturals: [`Nat`](https://internetcomputer.org/docs/motoko/base/Nat), [`Nat8`](https://internetcomputer.org/docs/motoko/base/Nat8), [`Nat16`](https://internetcomputer.org/docs/motoko/base/Nat16), [`Nat32`](https://internetcomputer.org/docs/motoko/base/Nat32), [`Nat64`](https://internetcomputer.org/docs/motoko/base/Nat64)

The [`Int`](https://internetcomputer.org/docs/motoko/base/Int) and [`Nat`](https://internetcomputer.org/docs/motoko/base/Nat) types prevent overflow and underflow since they can represent values of arbitrary size. Of course, subtraction on a `Nat` can still result in underflow if the result would be negative.

In Motoko, [`Nat`](https://internetcomputer.org/docs/motoko/base/Nat) is a subtype of [`Int`](https://internetcomputer.org/docs/motoko/base/Int), since the set of non-negative integers is a subset of all integers.

This means that every expression of type [`Nat`](https://internetcomputer.org/docs/motoko/base/Nat) can implicitly serve as an [`Int`](https://internetcomputer.org/docs/motoko/base/Int) without any need for conversion. The opposite is not true.

An [`Int`](https://internetcomputer.org/docs/motoko/base/Int) cannot be directly assigned to a [`Nat`](https://internetcomputer.org/docs/motoko/base/) since it may be a negative number and the [`Nat`](https://internetcomputer.org/docs/motoko/base/Nat) type only contains non-negative numbers.

```motoko
let x : Int = -5;
let y : Nat = x; // Error
```

Passing an [`Int`](https://internetcomputer.org/docs/motoko/base/Int) as a [`Nat`](https://internetcomputer.org/docs/motoko/base/Nat) equires an explicit conversion, such as taking the absolute value or applying another conversion function.

```motoko no-repl
let x : Int = -5;
let y : Nat = Int.abs(x); // Allowed, y = 5
```

Fixed-size numeric types ([`Int8`](https://internetcomputer.org/docs/motoko/base/Int8), [`Nat32`](https://internetcomputer.org/docs/motoko/base/Nat32), etc.) support additional operations, including bitwise shifts.

```motoko
let x : Nat32 = 0xA; // 10 in hexadecimal
let y = x << 2; // 0x28 (40 in decimal)
```

## `Char` and `Text`

`Char` represents a single Unicode scalar value, while [`Text`](https://internetcomputer.org/docs/motoko/base/Text) represents a sequence of characters.

```motoko
import Char "mo:base/Char";
import Text  "mo:base/Text";
import Text "mo:base/Text";
import Char "mo:base/Char";
let letter : Char = 'A';

let codePoint = Char.toNat32(letter); // 65

let word : Text = "Motoko";
let uppercase = Text.toUppercase(word); // "MOTOKO"

let modified = Text.replace("hello world", #text "world", "Motoko"); // "hello Motoko"
let words = Text.split("apple,banana,cherry", #char ','); // apple -> banana -> cherry
```

## Bool

The [`Bool`](https://internetcomputer.org/docs/motoko/base/Bool) type represents boolean values, `true` or `false`, and supports logical operations.

The logical operators `and` and `or` will only evaluate their second operand if necessary.

```motoko
let flag : Bool = true or false; // true
let opposite = not flag; // false

let isEqual =  true == false ; // false
```

## Float

[`Float`](https://internetcomputer.org/docs/motoko/base/Float) is a 64-bit floating-point type that provides mathematical operations.

```motoko
import Float "mo:base/Float";
let pi = Float.pi;
let radius : Float = 2.5;
let area = Float.pow(radius, 2) * pi; // Area of a circle

let rounded = Float.floor(4.8); // 4.0
let trigValue = Float.sin(Float.pi / 2); // 1.0
```

## Resources

- [`Int`](https://internetcomputer.org/docs/motoko/base/Int)
- [`Nat`](https://internetcomputer.org/docs/motoko/base/Nat)
- [`Bool`](https://internetcomputer.org/docs/motoko/base/Bool)
- [`Blob`](https://internetcomputer.org/docs/motoko/base/Blob)
- [`Char`](https://internetcomputer.org/docs/motoko/base/Char)
- [`Text`](https://internetcomputer.org/docs/motoko/base/Text)
- [`Float`](https://internetcomputer.org/docs/motoko/base/Float)

