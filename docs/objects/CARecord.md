# CARecord — array of structs (fixlen record view)

`CARecord` is the array-of-structs view: an array whose elements are instances
of a [CAStruct](../topics/CAFace.md) data class, laid out as one fixed-width record per
cell. It is a [Face](../topics/CAFace.md) — a semantic-identity view — over a plain
`CA_FIXLEN` storage array. The record bytes live in the parent entity; the
`CARecord` Face adds only the knowledge of *which struct class* those bytes
decode to.

```
GeoCoord = CArray.struct { float64 :lat; float64 :lng }   # 16-byte record

CARecord.new(GeoCoord, 3)          shape [3], each cell a 16-byte GeoCoord

  parent (CA_FIXLEN, bytes: 16) ─── stores the raw record bytes
  CARecord Face             ─── decodes cell i → GeoCoord instance
```

Being a Face, `CARecord`:

- **shares the parent's buffer byte-for-byte** — the storage layout is
  identical to a bare `CA_FIXLEN` array, and every view operation (slice,
  transpose, mask, gather) carries the record identity along the view chain;
- has surface `data_type == CA_FIXLEN`, which **gates off numeric kernels**
  (`record + record` is meaningless and raises) while whole-array structural
  operations still work;
- always sits at the **top** of a view chain.

## Defining the record type

The element type is a `CAStruct` data class, built with the `CArray.struct`
DSL:

```ruby
GeoCoord = CArray.struct { float64 :lat; float64 :lng }
GeoCoord::DATA_SIZE          # => 16   (bytes per record)

Pixel = CArray.struct { uint8 :r; uint8 :g; uint8 :b }
Pixel::DATA_SIZE            # => 3
```

## Construction

There are two entry points: allocate a fresh backing entity, or wrap an
existing one.

### `CARecord.new(data_class, *shape)` — allocate

```ruby
a = CARecord.new(GeoCoord, 5)
a.class                     # => CARecord
a.data_class                # => GeoCoord
a.shape                     # => [5]
a.parent.data_type          # => :fixlen   (the storage entity)

CARecord.new(GeoCoord, 3, 4)      # 2-D, shape [3, 4]
```

`data_class` must be a `CAStruct` subclass; anything else raises `TypeError`.

### `CARecord.wrap(entity, data_class)` — zero-copy wrap

Wrap a pre-existing `CA_FIXLEN` array (e.g. one you read from a file or received
over MemoryView) as records, without copying:

```ruby
ent = CArray.new(CA_FIXLEN, [3], bytes: GeoCoord::DATA_SIZE)
w   = CARecord.wrap(ent, GeoCoord)
w.parent.equal?(ent)        # => true   (no copy; writes go to ent)
```

### Subclass DSL

Pin the `data_class` on a named subclass so it takes the shape-only
constructor. This is the natural home for domain methods over the record array:

```ruby
class CAGeoCoord < CARecord
  data_class GeoCoord

  def centroid
    [self["lat"].mean, self["lng"].mean]
  end
end

g = CAGeoCoord.new(100)     # data_class is fixed to GeoCoord
g.data_class                # => GeoCoord
```

`data_class` is immutable once declared — re-declaring it on the subclass
raises.

> **Breaking change (3.0):** the legacy `CArray.new(MyStruct, [N])` form is
> removed. Use `CARecord.new(MyStruct, N)` or a `CARecord` subclass.

## Field access

Indexing a `CARecord` by **field name** projects a column view onto the
underlying bytes — a [CAField](../topics/CAFace.md) over the parent (the Face is stripped,
so the result is an ordinary numeric array you can compute on):

```ruby
a = CARecord.new(GeoCoord, 3)
a["lat"][] = [1.0, 2.0, 3.0]
a["lng"][] = [4.0, 5.0, 6.0]

a["lat"].class              # => CAField
a["lat"].to_a               # => [1.0, 2.0, 3.0]
a["lat"].mean               # => 2.0
```

Indexing by **integer** decodes a single cell to a struct instance:

```ruby
v = a[0]
v.class                     # => GeoCoord
v["lat"]                    # => 1.0
```

Field projection also works through derived views (a slice or transpose of a
`CARecord` can still project its fields):

```ruby
a["lat"][] = CArray.float64(3).seq   # [0.0, 1.0, 2.0]
a[1..2]["lat"].to_a                  # => [1.0, 2.0]
```

## Masking

Masks work as they do for any Face — the mask is carried, and masking a cell
marks the whole record:

```ruby
a = CARecord.new(GeoCoord, 5)
a.mask = 0
a[2] = UNDEF
a.count_masked              # => 1
a.mask.to_a                 # => [0, 0, 1, 0, 0]
```

## Ordering — by the members the struct declares

A record's bytes are no order of its values (a negative integer, a
little-endian float), so a record array has an order only when its struct
names one with `order_by:`.  The members are compared in the order given:

```ruby
Site = CArray.struct(order_by: [:lat, :lng]) { float64 :lat; float64 :lng }
a = CARecord.new(Site, 3)
a["lat"][] = [3.0, 1.0, 1.0]
a["lng"][] = [0.0, 5.0, 2.0]
a.sort_index.to_a           # => [2, 1, 0]   by lat, then lng
a.min.values                # => [1.0, 2.0]
a < a[0]                    # boolean, compared by the same order
a[1] < a[0]                 # => true   (the records compare too)
```

`sort`, `sort_copy`, `sort_addr`, `sort_index`, `rank_index`, `order`, `min`,
`max`, `minmax`, `min_index`, `max_index`, `partition_copy`, `partition_index`
and the comparison operators follow it.  NaN sorts after every number, and a
masked record stays masked.  `order_by:` names members that hold values; a
nested record is not one (order by its members instead).

A struct declared without `order_by:` has no order: those methods raise.  To
sort by one field without declaring an order, sort that field's projection:

```ruby
order = a["lat"].sort_index         # sort by lat numerically
a[order]                            # records in lat order
```

## Serialization

`dump_binary` / `load_binary` round-trip the record **bytes** (byte-exact, via
the parent), so the data survives a save/load cycle:

```ruby
bytes = a.dump_binary
b     = CARecord.new(GeoCoord, 3)
b.load_binary(bytes)
```

Note that the binary format carries the bytes only — the `data_class` identity
is not embedded, so you re-supply it by loading into a `CARecord` of the right
type. Preserving Face class identity across `dump_binary` / `Marshal` is a
post-3.0 topic and out of scope here.

## Class and hierarchy

- Ruby class `CARecord < CAFace < CAView < CArray`; a user subclass sits under
  `CARecord`.
- `obj_type` is `CA_OBJ_RECORD`; the Face gate is the `CA_FLAG_IS_FACE` flag.
- Storage operations (attach / sync / fill / xfer) thin-forward to the parent
  `CA_FIXLEN` entity, so a `CARecord` costs no more than its backing array.

## Related

- [CAFace](../topics/CAFace.md) — the semantic-identity view mechanism `CARecord` is
  built on, and the `CAStruct` / `CAField` building blocks.
- [FaceOrderingSearch](../authoring/FaceOrderingSearch.md) — how fixlen Faces sort and
  search, and the memcmp-vs-object ordering gate.
- [Serialization](../topics/Serialization.md) — serialize / deserialize via the `_CARRAY3` binary format.
