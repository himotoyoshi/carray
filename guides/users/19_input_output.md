# Input and output

This chapter covers getting data into a CArray and back out again. CArray's built-in I/O surface is deliberately small — for anything beyond plain Ruby values and in-process exchange with other array libraries, you reach for a dedicated gem — so this is a short chapter.

## From and to Ruby values

The most common exchange is with ordinary Ruby `Array`s. To build a CArray from values you already have, use a `CA_*` constructor (see [Creating arrays](01_creating_arrays.md)); the nesting of the Ruby array determines the shape.

```ruby
CA_INT([[1, 2, 3],
        [4, 5, 6]])
#  => [ [ 1, 2, 3 ],
#       [ 4, 5, 6 ] ]      a 2-D int32 CArray
```

`to_a` goes the other way, producing a nested Ruby `Array` with the same shape:

```ruby
a = CArray.int32(2, 3).seq
a.to_a
#  => [ [ 0, 1, 2 ], [ 3, 4, 5 ] ]
```

The two are inverses, so a round-trip through Ruby preserves shape and values:

```ruby
CA_INT(a.to_a).to_a == a.to_a    #  => true
```

`to_a` returns plain Ruby objects (`Integer`, `Float`, …). A masked element comes back as the `UNDEF` constant, so the mask survives a `to_a` but a plain Ruby `Array` has no separate notion of it — see [Masks and missing values](05_masks.md).

## Exchange with other array libraries

To move a whole buffer between CArray and another library — `Numo::NArray`, Apache Arrow, a PyCall NumPy array, a `Fiddle`-backed region — without going through Ruby `Array`s, use the **MemoryView** protocol. It exchanges the raw bytes plus shape and data_type directly, with no per-element Ruby crossing, and can be zero-copy.

```ruby
ca = CArray.from_memory_view(some_numo_array)   #  copy import
ca = CArray.wrap_memory_view(some_numo_array)   #  zero-copy view
```

This is the right tool whenever the other side already holds the data in a contiguous (or strided) numeric buffer. See [MemoryView interop](15_memory_view.md) for the full story, including the export direction (handing a CArray to any consumer) and the mask-handling rules.

## Persistence: saving and loading arrays

To write an array to disk and read it back, use `CArray.save` and `CArray.load`:

```ruby
a = CArray.float64(2, 3).seq
CArray.save(a, "result.ca")

b = CArray.load("result.ca")
b == a       #  => true
```

Both take a filename or an open IO, so you can also stream through a pipe or a `StringIO`. `CArray.dump` returns the same bytes as a String without touching the filesystem, and `CArray.load` accepts such a String directly:

```ruby
blob = CArray.dump(a)        #  => a binary String
CArray.load(blob) == a       #  => true
```

### What round-trips

A round-trip preserves everything that describes the array as a numeric container: **shape, data type, and the mask**. Missing elements come back masked, not as stray data:

```ruby
a = CArray.int32(4).seq
a[2] = UNDEF
b = CArray.load(CArray.dump(a))
b[2]              #  => UNDEF   (still masked)
b == a           #  => true
```

Attributes attached with `set_attr` — units, fill values, and other JSON-compatible metadata — survive the round-trip too, including non-finite Float values such as `Float::INFINITY`:

```ruby
a = CArray.float64(4).seq
a.set_attr(:units, "m/s")
a.set_attr(:fillvalue, Float::INFINITY)

b = CArray.load(CArray.dump(a))
b.attr("units")      #  => "m/s"
b.attr("fillvalue")  #  => Infinity
```

A record array (a [Face](12_faces.md) over a `data_class`) round-trips as well: a named record class comes back as itself, and an anonymous one is reconstructed field-for-field from the schema stored in the file, so the layout stays readable outside Ruby too.

### Choosing the byte order

By default a writer emits the host's native byte order and never swaps on write; a reader detects the file's order from a marker in the header and swaps into the host order automatically. A file written on one architecture therefore reads correctly on another with no action from the caller.

Pass `endian:` to force a specific order — useful when you want a fixed on-disk representation regardless of where the writer is running:

```ruby
CArray.save(a, "big_endian.ca", endian: CA_BIG_ENDIAN)
CArray.save(a, "little.ca",     endian: CA_LITTLE_ENDIAN)
```

### Reinterpreting a bare record — `data_type:`

A packed fixed-length payload with no attached record layout comes back as a raw fixed-length byte array. Pass `data_type:` to `load` to reinterpret those bytes as a specific element type instead — useful when the data was produced by another program that packed, say, `float64` records without attaching CArray metadata:

```ruby
CArray.load("packed.ca", data_type: CA_FLOAT64)
```

### What cannot be saved

An [object array](13_object_arrays.md) (arbitrary Ruby objects per cell) has no portable raw representation, so `CArray.save` and `CArray.dump` **raise** on one. Persist object arrays with `Marshal` instead (below); a record array whose fields are all primitive types is fine and does round-trip.

### The file is meant to be read from other languages

The on-disk layout puts the raw numeric payload at a **fixed byte offset in a single, file-wide byte order**, so a program in C, FORTRAN, or any language with raw file access can reach the data with one seek — no Ruby needed on the other end. This is the point of the format: hand a computation result to the next process, whatever language it is written in. CArray-native concepts — the attribute map, the record schema, the mask — ride in a small text trailer at the tail of the file that a non-Ruby reader can safely skip. The file itself carries the offsets that say where the payload, the mask, and the trailer begin, so a reader never has to compute them by hand.

The format is meant for **temporary workflow handoff** — dump a result, hand it to the next process, consume, discard. For long-term archival, export to a mature format designed for it (NetCDF, HDF5, Parquet).

## Object arrays: `Marshal`

An [object array](13_object_arrays.md) — one whose cells hold arbitrary Ruby objects — has no portable raw representation, so `CArray.save` and `CArray.dump` **raise** on one. Persist an object array with `Marshal` instead. This is Ruby-only and makes no cross-language promise, but it does round-trip anything a `Marshal` on the cell values themselves would:

```ruby
objs = CArray.object(3) { |i| { id: i, label: "row-#{i}" } }

File.binwrite("objs.marshal", Marshal.dump(objs))
Marshal.load(File.binread("objs.marshal"))
```

`Marshal` also works for every non-object array — a numeric array simply reuses the same portable binary format underneath. So only the portable `.ca` file is object-free; the choice between `.ca` and `Marshal` is really "cross-language handoff or not", not "numeric or not".

### Choosing a persistence route

- **Same project, quick handoff, any language on the other end** — `CArray.save` / `CArray.load`.
- **A cell holds arbitrary Ruby objects** — `Marshal`.
- **The data already lives in another array library** (`Numo::NArray`, Arrow, a NumPy array via PyCall) — exchange the buffer through [MemoryView](15_memory_view.md) rather than a file.
- **Long-term archival** — export to a dedicated format (NetCDF, HDF5, Parquet). The `.ca` format is built for temporary workflow files, not archives.
