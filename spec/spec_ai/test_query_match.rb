require 'test/unit'
require 'carray'

# A value query meets its reference in the type the two match in, as `eq`
# compares them: never cut to the reference's type (1.5 does not match 1,
# -1 does not read as 255), and an Integer the reference's type cannot
# hold matches nothing.  Every method that matches values answers as `eq`.
class TestQueryMatch < Test::Unit::TestCase

  TYPES = %i[int8 uint8 int16 uint16 int32 uint32 int64 uint64 float32 float64]

  VALUES = [0, 1, 3, 127, 255, 65535, 2**31, 2**53 + 1]

  QUERIES = [-1, 0, 1, 3, 127, 128, 255, 256, 300, 65535, 65536, 2**31, 2**32,
             2**53 + 1, 2**63, 2**64, -(2**63) - 1, 2**70, 1.5, 3.0, -1.0, 1e300]

  def self.reference (t)
    a = CArray.new(t, [VALUES.size])
    VALUES.each_with_index do |v, i|
      begin
        a[i] = v
      rescue RangeError
        a[i] = 0
      end
    end
    a
  end

  # name => [op(ref, q) for a scalar q, the answer derived from ref.eq(q)]
  SCALAR = {
    "count"       => [->(a, q) { a.count(q) },          ->(a, e) { e.count(true) }],
    "count axis"  => [->(a, q) { a.reshape(2, 4).count(q, axis: 1).to_a },
                      ->(a, e) { e.each_slice(4).map { |r| r.count(true) } }],
    "search"      => [->(a, q) { a.search(q) },         ->(a, e) { e.index(true) }],
    "search_addr" => [->(a, q) { a.search_addr(q) },    ->(a, e) { e.index(true) }],
    "mask_eq"     => [->(a, q) { a.mask_eq(q).is_masked.to_a }, ->(a, e) { e }],
    "is_in"       => [->(a, q) { a.is_in(q).to_a },     ->(a, e) { e }],
    "bsearch"     => [->(a, q) { s = a.sort.copy; i = s.bsearch(q); i && s.eq(q)[i] },
                      ->(a, e) { e.any? ? true : nil }],
  }

  def test_every_scalar_query_answers_as_eq
    wrong = []
    TYPES.each do |t|
      a = self.class.reference(t)
      QUERIES.each do |q|
        e = a.eq(q).to_a
        SCALAR.each do |name, (op, want)|
          got = begin; op.call(a, q); rescue StandardError => x; x.class; end
          wrong << "#{t} #{name}(#{q})" unless got == want.call(a, e)
        end
      end
    end
    assert_equal [], wrong
  end

  def self.array_of (t, vals)
    a = CArray.new(t, [vals.size])
    a[] = CA_OBJECT(vals)
    a
  end

  POOL = [-1, 0, 1, 2, 3, 127, 128, 200, 255, 256, 300, 65535, 2**31,
          2**53 + 1, -(2**40), 1.5, 2.5, 3.0]

  def self.values_of (t)
    POOL.select { |v|
      next false if v.is_a?(Float) && t.to_s.include?("int")
      begin
        array_of(t, [v])[0] == v
      rescue StandardError
        false
      end
    }.first(8).then { |v| v + [v[0]] * (8 - v.size) }
  end

  def exact_eq (x, y)
    x.to_r == y.to_r
  end

  # Two arrays: each method that matches the values of one in the other.
  def test_every_array_query_matches_by_value
    wrong = []
    TYPES.product(TYPES).each do |ta, tb|
      va = self.class.values_of(ta)
      vb = self.class.values_of(tb).rotate(1)
      a = self.class.array_of(ta, va)
      b = self.class.array_of(tb, vb)
      expect = {
        "count"        => [a.count(b).to_a, vb.map { |y| va.count { |x| exact_eq(x, y) } }],
        "search"       => [a.search(b).to_a, vb.map { |y| va.index { |x| exact_eq(x, y) } || UNDEF }],
        "is_in"        => [a.is_in(b).to_a, va.map { |x| vb.any? { |y| exact_eq(x, y) } }],
        "locate_addr"  => [a.locate_addr(b).to_a, va.map { |x| vb.index { |y| exact_eq(x, y) } || UNDEF }],
        "intersection" => [a.intersection(b).elements,
                           va.select { |x| vb.any? { |y| exact_eq(x, y) } }.uniq(&:to_r).size],
        "eq"           => [a.eq(b).to_a, va.zip(vb).map { |x, y| exact_eq(x, y) }],
      }
      expect.each { |name, (got, want)| wrong << "#{ta}/#{tb} #{name}" unless got == want }
    end
    assert_equal [], wrong
  end

  # A query of another kind meets the reference as eq does: an object
  # query by Ruby ==, a string or a time refused.
  def test_a_query_of_another_kind_answers_as_eq
    i = CA_INT32([1, 2, 3])
    o = CA_OBJECT([1, 2.5, "a"])
    assert_equal [1, 0, 0], i.count(o).to_a
    assert_equal [0, UNDEF, UNDEF], i.search(o).to_a
    f = CArray.fixlen(3, bytes: 2) { "ab" }
    assert_raise_kind_of(TypeError) { i.eq(f) }
    assert_raise_kind_of(TypeError) { i.count(f) }
    assert_raise_kind_of(TypeError) { i.search(f) }
  end

  # result_type gives an Integer the array's type cannot hold a type that
  # holds it and the array's values, so the set family built on it answers
  # as eq does.
  def test_result_type_keeps_an_integer_that_does_not_fit
    assert_equal :int64,  CArray.result_type(CA_UINT8([1]), -1)
    assert_equal :int64,  CArray.result_type(CA_INT8([1]), 200)
    assert_equal :object, CArray.result_type(CA_UINT64([1]), -1)
    assert_equal :object, CArray.result_type(CA_INT8([1]), 2**63)
    assert_equal :object, CArray.result_type(CA_INT8([1]), 2**70)
    a = CA_INT8([0, 1, 3])
    assert_equal [false, false, false], a.is_in(2**70).to_a
    assert_equal [false, true, false], a.is_in([2**63, 1]).to_a
    assert_equal [false, true], CA_UINT64([2**64 - 1, 1]).is_in([-1, 1]).to_a
  end

  # The tables above are every method that matches a query's values; a new
  # one is added to them, or here with the reason it is not.
  NOT_MEASURED = {
    search_ki: "the kernel search calls", search_addr_ki: "the kernel search_addr calls",
    bsearch_ki: "the kernel bsearch calls", bsearch_addr_ki: "the kernel bsearch_addr calls",
    search_nearest_ki: "the kernel search_nearest calls",
    search_nearest_addr_ki: "the kernel search_nearest_addr calls",
    bsearch_addr: "bsearch with addresses", search_nearest: "nearest, not equality",
    search_nearest_addr: "nearest, not equality", locate_nearest_addr: "nearest, not equality",
    count_masked: "counts masks", count_not_masked: "counts masks",
    difference: "the set family, measured through intersection",
    union: "the set family, measured through intersection",
    is_mode: "frequencies, not a query",
  }
  QUERY_NAME = /\A(count|search|bsearch|is_in\z|locate|intersection|difference|union|mask_eq)/

  def test_every_query_method_is_measured
    covered = (SCALAR.keys + %w[count search is_in locate_addr intersection eq])
                .map { |k| k[/\A\w+/].to_sym }.uniq
    found = CArray.public_instance_methods(true).grep(QUERY_NAME)
    assert_equal [], (found - covered - NOT_MEASURED.keys).sort
  end
end
