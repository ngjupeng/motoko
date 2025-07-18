---
sidebar_position: 12
---

# Advanced types

Advanced type features enable more flexible and expressive type definitions, including structural equality, generic types, subtyping, recursive types, and type bounds.

## Structural equality

Structural equality determines whether two values are equal based on their contents. This applies to immutable data structures, such as [records](https://internetcomputer.org/docs/motoko/fundamentals/types/records) and [variants](https://internetcomputer.org/docs/motoko/fundamentals/types/variants), but does not apply to mutable structures for safety reasons.

```motoko
type Point = { x : Int; y : Int };

let p1 : Point = { x = 1; y = 2 };
let p2 : Point = { x = 1; y = 2 };

p1 == p2;  // true (structural equality)
```

Even though `p1` and `p2` are distinct objects, they are considered equal because they have the same structure and values.

This remains true even if different fields are added to the point values, since the `==` on `Point`  values only considers the `x` and `y` fields and ignores other fields.

```motoko
type Point = { x : Int; y : Int };

let p1 : Point = { x = 1; y = 2; z = 3 };
let p2 : Point = { x = 1; y = 2; z = 4; c = "Red"; };

p1 == p2;  // true (structural equality at type `Point`)
```

## Generic types

Generic types are used to define type parameters that work with multiple data types, commonly used in [functions](https://internetcomputer.org/docs/motoko/fundamentals/types/functions), [classes](https://internetcomputer.org/docs/motoko/fundamentals/types/objects-classes), and data structures.

```motoko
// Generic function
func identity<T>(x : T) : T {
  return x;
};

identity<Nat>(42);  // num is Nat
```

A generic class can store any type while maintaining type safety:

```motoko
class Box<T>(value : T) {
  public func open() : T { value };
};

let intBox = Box<Nat>(10);
intBox.open();
```

## Recursive types

Recursive types allow a type to refer to itself, enabling the creation of nested structures while maintaining type safety. The base package utilizes recursive types to define linked lists.

```motoko no-repl
type List = ?(Nat, List);
```

This defines a recursive type for representing a linked list of natural number. Each list is either:

- `null`, representing the empty list.

- `?(head, tail)`, where `head` is a `Nat` and `tail` is another `List`.

```motoko
?(1, ?(2, ?(3, null)))  // A list: 1 → 2 → 3
```

To generalize this structure and support values of any type, we introduce a parameterized type:

```motoko no-repl
type List<T> = ?(T, List<T>);
```

This defines a generic linked list, where `T` can be any type (`Nat`, `Text`, `Blob`, or a custom type).

### Manually reversing a linked list

Reversing a linked list involves iterating through the list and prepending each element to a new list. This approach demonstrates list traversal without using `List.reverse` library function.

Non-parameterized type:

```motoko name=List
// Lists of naturals
type List = ?(Nat, List);

// Reverses List
func reverseNat(l : List) : List {
  var current = l;
  var rev : List = null;

  loop {
    switch (current) {
      case (?(head, tail)) {
        rev := ?(head, rev);
        current := tail;
      };
      case (null) {
        return rev;
      };
    };
  };
};
```

```motoko _include=List no-repl
let numbers : List = ?(1, ?(2, ?(3, null)));
reverseNat(numbers); // ?(3, ?(2, ?(1, null)))
```

Parameterized:

```motoko name=GenList
// Lists of naturals
type List<T> = ?(T, List<T>);

// Reverses List
func reverse<T>(l : List<T>) : List<T> {
  var current = l;
  var rev : List<T> = null;
  loop {
    switch (current) {
      case (?(head, tail)) {
        rev := ?(head, rev);
        current := tail;
      };
      case (null) {
        return rev;
      };
    };
  };
};
```

These type and function definitions generalize the previous code to work not just on lists of `Nat`s, but on lists of `T` values, for any type `T`.

You can reverse a list of numbers.

``` motoko _include=GenList no-repl
let numbers : List<Nat> = ?(1, ?(2, ?(3, null)));
reverse<Nat>(numbers); // ?(3, ?(2, ?(1, null)))
```
But you can also reverse a list of characters:

```motoko _include=GenList no-repl

let chars : List<Char> = ?('a', ?('b', ?('c', null)));
reverse<Char>(numbers); // ?('c', ?('b', ?('a', null)))
```

Notice how generic types and generic functions complement each other.

## Type bounds

Generic types can use subtype constraints, ensuring that any type used in a generic function meets specific structural or concrete type requirements.

These constraints are enforced at compilation. This guarantees that the necessary properties or operations are available when the function is used, eliminating certain classes of runtime errors.

Although the concept of type bounds is often associated with [inheritance-based polymorphism](https://www.codecademy.com/learn/learn-java/modules/learn-java-inheritance-and-polymorphism/cheatsheet) in other languages, Motoko uses structural typing. This means that the subtype relationship is determined by the structure of the types rather than an explicit inheritance hierarchy. **Motoko does not support inheritance**.

This approach balances the flexibility of generic programming with the safety of compile-time checks, enabling the creation of generic functions that operate on a range of types while still enforcing specific structural or type constraints.

<!-- TODO better example that requires bounds (this one doesn't) -->
The following examples illustrate this behavior:

```motoko
func printName<T <: { name : Text }>(x : T): Text {
  debug_show(x.name);
};

let ghost = { name = "Motoko"; age = 30 };
printName(ghost);  // Allowed since 'ghost' has a 'name' field.
```

In the example above, `T <: { name : Text }` requires that any type used for `T` must be a subtype of the [record](https://internetcomputer.org/docs/motoko/fundamentals/types/records) `{ name : Text }`, that is, it must have at least a `name` field of type [`Text`](https://internetcomputer.org/docs/motoko/base/Text). Extra fields are permitted, but the `name` field is mandatory.

Type bounds are not limited to records.
In general, the notation `T <: A` in a parameter declaration mandates that any type provided for type parameter `T` must be a subtype of the specified type `A`.
For example, it is possible to constrain a generic type to be a subtype of a primitive type.

```motoko name=max
func max<T <: Int>(x : T, y : T) : T {
  if (x <= y) y else x
};
max<Int>(-5, -10);  // returns -5  : Int
```

Here, `T <: Int` constrains `T` to be a subtype of [`Int`](https://internetcomputer.org/docs/motoko/base/Int), ensuring that arithmetic operations are valid.

But the function can also be used to return the maximum of two `Nat`s and still produce a `Nat` (not an `Int`).

```motoko _include=max no-repl
max<Nat>(5, 10); // returns 10 : Nat
```

