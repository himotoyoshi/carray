# DOCUMENTATION ONLY — DO NOT REQUIRE.
# Stubs for methods defined in ext/carray_sort.c.
# See yard-stubs/README.md and yard-stubs/STYLE.md.

class CArray
  # @!group Sorting and searching

  # @overload sort_addr(*keys, masked_position: :last)
  #   Returns a 1-D CArray of `:int64` indices that lex-sort `keys`
  #   in priority order (`keys[0]` is highest priority,
  #   `keys[1]` breaks ties, etc.). All `keys` must share the same
  #   element count.
  #
  #   Masked cells are an incomparable sentinel clustered at
  #   `masked_position:` (`:last`, default, or `:first`), applied
  #   uniformly across all `keys`. Ties are broken by original index
  #   (stable).
  #
  #   @example
  #     idx = CArray.sort_addr(a, b, c)  # priority: a > b > c
  #     a[idx]; b[idx]; c[idx]
  #
  #   @param keys [Array<CArray>] one or more CArrays, all of the
  #     same element count.
  #   @param masked_position [Symbol] `:last` (default) or `:first`.
  #   @return [CArray] flat `:int64` indices, shape `[a.elements]`.
  #   @raise [ArgumentError] when no key is given or element counts
  #     differ.
  def self.sort_addr(*keys, masked_position: :last); end

  # @overload sort(axis: nil, kind: :quick, masked_position: :last)
  #   Returns a `CARemap` view of `self` whose elements are sorted
  #   along `axis`. When `axis` is omitted, `self` is first
  #   flattened to 1-D and the entire array is sorted (so the
  #   result is a 1-D view regardless of `self.ndim`).
  #
  #   `kind:` selects the sorting algorithm. Both kinds are stable
  #   (tie-broken by fiber-local index); the choice is a
  #   performance characteristic only:
  #
  #   - `:quick` (default) — portable textbook introsort with
  #     mergesort escape. Faster on random data.
  #   - `:stable` — portable bottom-up mergesort with insertion
  #     pre-pass. Predictable worst case.
  #
  #   Masked cells are an incomparable sentinel (the same role NaN
  #   plays for float dtypes): they are excluded from the value
  #   comparison and clustered at one end of each fiber.
  #   `masked_position:` picks which end (`:last`, default, or
  #   `:first`); relative order within the masked cluster is
  #   unspecified. Masked cells keep their masked-ness at the
  #   clustered position (the `CARemap` gather carries the mask bit
  #   through, no separate output-mask step needed).
  #
  #   Supports numeric (`i8`..`f64`), `CA_FIXLEN` (via memcmp
  #   lexicographic order), and `CA_OBJECT` (via `<=>` per pair) --
  #   all through the same view path, `masked_position:` included.
  #   @param axis [Integer, nil]
  #   @param kind [Symbol] `:quick` or `:stable`.
  #   @param masked_position [Symbol] `:last` (default) or `:first`.
  #   @return [CArray] sorted view.
  def sort(axis: nil, kind: :quick, masked_position: :last); end

  # @overload sort_copy(axis: nil, kind: :quick, masked_position: :last)
  #   Eager-copy counterpart of {#sort}: returns a fresh entity
  #   CArray with the same shape and `data_type` as `self`, sorted
  #   along `axis`. Use this when you want an independent array
  #   rather than a view.
  #
  #   Unmasked numeric paths use a per-fiber gather + sort +
  #   scatter, bypassing the `CARemap` scatter layer that `sort`
  #   uses. `CA_FIXLEN` and masked input both materialize the
  #   `sort` view instead (same shape, ordering, and
  #   `masked_position:` semantics as {#sort}).
  #   @param axis [Integer, nil]
  #   @param kind [Symbol] `:quick` or `:stable`.
  #   @param masked_position [Symbol] `:last` (default) or `:first`.
  #   @return [CArray]
  def sort_copy(axis: nil, kind: :quick, masked_position: :last); end

  # @overload sort_addr(axis: nil, kind: :quick, masked_position: :last)
  #   Returns view-flat addresses that index a sort.
  #
  #   - With no kwarg (`a.sort_addr`): returns a CArray of `:int64`
  #     flat addresses shaped like `self` (NOT flattened -- the
  #     legacy 1-key case of `CArray.sort_addr`'s multi-key lex
  #     sort). `kind:` has no effect on this form.
  #   - With `axis:` (e.g. `a.sort_addr(axis: 0)`): returns
  #     per-fiber view-flat addresses along the given axis, output
  #     shape == `self.shape`.
  #
  #   `kind:` selects the sort algorithm for the `axis:` path:
  #
  #   - `:quick` (default) — introsort with mergesort escape.
  #   - `:stable` — bottom-up mergesort.
  #
  #   Both kinds are algorithmically stable (pair sort with index
  #   tie-break); `kind:` chooses the performance characteristic.
  #
  #   `masked_position:` (`:last` default, or `:first`) picks which
  #   end masked cells cluster to. Effective on both forms: the
  #   `axis:` path forwards to the `sort`/`sort_index` kernel family;
  #   the no-`axis:` path forwards to `CArray.sort_addr`'s own
  #   masked-position-aware comparator.
  #
  #   Companion of {#axis2addr} (axis-local indices to view-flat
  #   addresses) and {#sort} (the view counterpart).
  #   @param axis [Integer, nil]
  #   @param kind [Symbol] `:quick` or `:stable`.
  #   @param masked_position [Symbol] `:last` (default) or `:first`.
  #   @return [CArray] `:int64` addresses.
  #   @raise [ArgumentError] when `kind:` is neither `:quick` nor
  #     `:stable`.
  def sort_addr(axis: nil, kind: :quick, masked_position: :last); end

  # @!group Index and address conversion

  # @overload axis2addr(indices, axis: 0)
  #   Converts per-fiber axis-local indices into row-major
  #   view-flat addresses into `self`. For each cell at coord
  #   `c = (c_0, ..., c_(n-1))` in `indices`:
  #
  #     addr[c] = sum over `j != axis` of c_j * stride_j +
  #               indices[c] * stride_axis
  #
  #   where strides are row-major over `self.shape`.
  #
  #   Canonical converter between the two axis-position
  #   representations the `*_index` / `*_addr` kernel families
  #   produce:
  #
  #   @example
  #     a.min_index(axis: k)  # axis-local scalar per fiber
  #     a.min_addr(axis: k)   # view-flat address per fiber
  #     flat = key.axis2addr(key.min_index(axis: k), axis: k)
  #     # flat == key.min_addr(axis: k)
  #
  #   Sits underneath `#take_along_axis`: the heavy "axis-local
  #   -> view-flat" arithmetic lives here, and `take_along_axis`
  #   is a one-liner on top of `flatten[axis2addr(...)]`.
  #
  #   Shape rule: `indices.ndim == self.ndim`, and
  #   `indices.dim[j] == self.dim[j]` for all `j != axis`;
  #   `indices.dim[axis]` is free.
  #
  #   `indices` data_type: any integer kind (zero-copy when
  #   already `:int64`). Negative indices: Python-style
  #   (`-1` == last). Out-of-range indices raise `RangeError`.
  #   Negative `axis:` is Python-style.
  #
  #   @param indices [CArray] integer-typed axis-local positions.
  #   @param axis [Integer] axis along which `indices` are
  #     interpreted.
  #   @return [CArray] `:int64` view-flat addresses, same shape as
  #     `indices`.
  #   @raise [RangeError] when an index is out of range after
  #     negative normalization.
  #   @raise [ArgumentError] for shape / ndim / data_type
  #     violations.
  def axis2addr(indices, axis: 0); end

  # @!endgroup
end
