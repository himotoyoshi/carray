# CABitarray — per-bit boolean view of an array

`CABitarray` fans every cell of a parent array out into its individual bits,
one boolean cell per bit. It is CArray's sub-byte view: no data is copied, the
bits are read (and written) straight out of the parent's bytes on demand.

```
parent = uint8 [0xFF, 0x0F]        (2 cells, 1 byte each)

parent.bits                        shape [2, 8], data_type :boolean

  bit axis →   0  1  2  3  4  5  6  7
  0xFF  →    [ 1  1  1  1  1  1  1  1 ]
  0x0F  →    [ 1  1  1  1  0  0  0  0 ]
```

A `CABitarray` appends **one trailing bit axis** to the parent's own axes. For
a parent of shape `S` whose elements are `B` bytes wide, the view has

```
view.shape      == [*parent.shape, B * 8]
view.data_type  == :boolean
```

Bits are extracted **LSB-first within each byte**: `view[..., 0]` is bit 0 (the
least-significant bit), `view[..., 7]` is bit 7, and so on.

## Construction

`CArray#bitarray` (aliased `#bits`) builds the view. It takes no arguments — the
bit axis length is determined by the parent's byte width.

```ruby
a  = CArray.uint8(4) { |i| [0xFF, 0x0F, 0xAA, 0x55][i] }
ba = a.bits                 # or a.bitarray

ba.shape                    # => [4, 8]
ba.data_type                # => :boolean

ba[0, nil].to_a             # => [1, 1, 1, 1, 1, 1, 1, 1]   (0xFF)
ba[2, nil].to_a             # => [0, 1, 0, 1, 0, 1, 0, 1]   (0xAA, LSB-first)
```

The bit axis is always **last**, and its length scales with the element width:

```ruby
CArray.uint8(3, 4).bits.shape    # => [3, 4, 8]
CArray.uint32(3, 4).bits.shape   # => [3, 4, 32]
```

## Reading and writing

`CABitarray` is a live view, not a snapshot. Reads pull the current parent
bytes; writes flow straight back:

```ruby
a = CArray.uint8(4) { 0 }
a.bits[1..2, nil] = 1       # set every bit of bytes 1 and 2
a.to_a                      # => [0, 255, 255, 0]

a.bits[0, 0] = 1            # set bit 0 of byte 0
a[0]                        # => 1
```

Because eight view cells (the eight bits of one byte) share a single parent
byte, an arbitrary partial write is applied as a read-modify-write on that byte,
so overlapping bit writes compose correctly. A whole-view assignment takes a
packed fast path instead.

## Endianness

For single-byte parents the bit axis is linear on every host. For multi-byte
numeric parents on **big-endian** hosts, the bytes within each element are
walked in reverse so the bit axis reflects network byte order regardless of the
host. On the common little-endian hosts this makes no observable difference.

## Restrictions

- **Parent `data_type`** — the parent must be an integer, float, boolean, or
  fixlen type. Complex and object parents raise `CADataTypeError` (a bit-level
  view of those is meaningless).
- **MemoryView** — `CABitarray` is **rejected** by the MemoryView protocol
  (`CArray.memory_view_available?(ba)` is `false`); a 1-bit-per-boolean-cell
  layout has no PEP 3118 format. Materialize with `.to_ca` first if a
  consumer needs contiguous bytes.
- **Not fold-collapsible** — the per-bit transform cannot be folded into a
  strided view chain the way `CAStride`-family views are, so a bitarray always
  sits as its own step in a view chain.

## Related

- [String arrays](../topics/StringArrays.md) and [CAConstString](CAConstString.md) — other
  non-numeric storage views.
- [`to_bit_string` / `from_bit_string`](../../yard-stubs/ca_obj_array.rb) — pack a
  boolean array to / from a packed-bit `String` (a different, eager operation:
  a `String` result, not a live view).
- `#bitfield` builds a `CABitfield` — a view of a **contiguous run of bits**
  interpreted as an integer, rather than one boolean per bit.
