# Random cases for CAStack and CAMeld, each checked against an entity.
#
# A case builds a stack or meld V over freshly made parents and,
# independently, an entity R holding the same cells, built only from
# entity operations on copies of the parents.  The same chain of views and
# the same last operation are applied to both, and the answers (values,
# masks, the class of an exception) must agree:
#
#   - a read must also leave every parent as it was, and give no parent
#     without a mask a mask
#   - a write is read back through a new view over the same parents and
#     compared with R
#   - a write that V refuses must leave every parent as it was; V may
#     refuse it where R takes it only for a part that cannot take it (a
#     frozen or lazy part)
#
# Parents: entities, blocks, transposes, frozen and lazy arrays, and
# stacks and melds of these, with or without masks; shapes with
# axes of length 0 and 1; int32, float64, uint8 and object.  The values are
# small integers, so every reduction is exact in every type.  What a masked
# cell holds is not defined, so nothing here reads it: no `value` (as an
# operation or a parent), and no `unmask` without a value.
#
# Shared by test_stack_meld_matrix.rb.  Run directly to walk more cases:
#
#   ruby -Iext -Ilib spec/spec_ai/stack_meld_cases.rb [cases] [seed]
#
#   CARRAY_GENERAL_PATH=1 / 2, CARRAY_SHORTCUTS_OFF=name,...  the route taken
#   FORK=n   n cases per child process, so a crash costs only its batch
#   ONLY=c   case c alone (a case is made from the seed and its number)
#   SHOW=n   the first n mismatches printed (default 40)

require "carray"

module StackMeldCases

  TYPES = [CA_INT32, CA_FLOAT64, CA_UINT8, CA_OBJECT]

  # What a write may meet where the entity takes it.
  REFUSAL = /can not modify read-only array/

  class Gen

    def initialize (seed)
      @r = Random.new(seed)
    end

    def int (n)
      return @r.rand(n)
    end

    def pick (a)
      return a[@r.rand(a.size)]
    end

    def chance (p)
      return @r.rand < p
    end

    def dim
      return chance(0.08) ? 0 : 1 + int(3)
    end

    def entity (type, shape, masked)
      e = CArray.new(type, shape)
      n = e.elements
      if n > 0
        e[] = CArray.int32(n).map! { int(7) + 1 }.reshape(*shape).to_type(type)
        if masked
          e[CArray.boolean(n).map! { chance(0.25) ? 1 : 0 }.reshape(*shape)] = UNDEF
        end
      end
      return e
    end

    # A parent of the given shape: [array, model, text, restricted].  The
    # model is an entity with the same cells, built without a stack or
    # meld; restricted says a write to it may be refused.
    def parent (type, shape, depth, writable)
      kinds = [:entity, :entity, :block, :transpose, :frozen]
      kinds << :lazy if not writable or chance(0.3)
      kinds += [:stack, :meld] if depth < 1 and shape.size >= 1
      kind = pick(kinds)
      kind = :entity if kind == :stack and ( shape.size < 2 or shape[0] < 1 )
      kind = :entity if kind == :meld and shape[0] < 2
      kind = :entity if kind == :transpose and shape.size < 2
      masked = chance(0.35)
      m = masked ? "+mask" : ""
      case kind
      when :entity
        e = entity(type, shape, masked)
        return [e, e.copy, "entity#{m}", false]
      when :frozen
        e = entity(type, shape, masked).freeze
        return [e, e.copy, "frozen#{m}", true]
      when :block
        base = entity(type, shape.map { |d| d * 2 + 1 }, masked)
        v = base[*shape.map { |d| [1, d, 2] }]
        return [v, v.copy, "block#{m}", false]
      when :transpose
        v = entity(type, shape.reverse, masked).transpose
        return [v, v.copy, "transpose#{m}", false]
      when :lazy
        base = entity(( type == CA_OBJECT ) ? CA_INT32 : type, shape, masked)
        base = base.to_type(type) if type == CA_OBJECT
        return [base.lazy + 0, base.copy, "lazy#{m}", true]
      when :stack
        sub = shape[1..-1]
        ps = (0...shape[0]).map { parent(type, sub, depth + 1, writable) }
        v = CArray.stack(ps.map { |p| p[0] }, axis: 0)
        ref = CArray.new(type, shape)
        ps.each_with_index { |p, i| ref[i, *([nil] * sub.size)] = p[1] }
        frozen = chance(0.15)
        v.freeze if frozen
        return [v, ref, "#{frozen ? 'frozen ' : ''}stack(#{ps.map { |p| p[2] }.join(',')})",
                ( frozen or ps.any? { |p| p[3] } )]
      when :meld
        n0 = int(shape[0] + 1)
        rest = shape[1..-1]
        a = parent(type, [n0] + rest, depth + 1, writable)
        b = parent(type, [shape[0] - n0] + rest, depth + 1, writable)
        v = CArray.meld(a[0], b[0], axis: 0)
        ref = CArray.new(type, shape)
        tail = [nil] * rest.size
        ref[0...n0, *tail] = a[1] if n0 > 0
        ref[n0..-1, *tail] = b[1] if shape[0] > n0
        frozen = chance(0.15)
        v.freeze if frozen
        return [v, ref, "#{frozen ? 'frozen ' : ''}meld(#{a[2]},#{b[2]})",
                ( frozen or a[3] or b[3] )]
      end
    end

    # [V, R, parents, text, rebuild, restricted]; rebuild makes a new view
    # over the same parents.
    def subject (writable)
      type = pick(TYPES)
      ndim = 1 + int(3)
      shape = (0...ndim).map { dim }
      if chance(0.5)
        k = 1 + int(3)
        axis = int(ndim + 1)
        ps = (0...k).map { parent(type, shape, 0, writable) }
        arrays = ps.map { |p| p[0] }
        v = CArray.stack(arrays, axis: axis)
        r = CArray.new(type, shape.dup.insert(axis, k))
        ps.each_with_index do |p, i|
          idx = [nil] * r.ndim
          idx[axis] = i
          r[*idx] = p[1]
        end
        text = "stack(axis: #{axis}, #{CArray.data_type_name(type)}, #{shape.inspect})"
        rebuild = -> { CArray.stack(arrays, axis: axis) }
      else
        axis = int(ndim)
        lens = (0...(1 + int(3))).map { int(4) }
        lens[0] = 1 if lens.sum == 0 and chance(0.8)
        ps = lens.map { |l| s = shape.dup; s[axis] = l; parent(type, s, 0, writable) }
        arrays = ps.map { |p| p[0] }
        v = CArray.meld(*arrays, axis: axis)
        rshape = shape.dup
        rshape[axis] = lens.sum
        r = CArray.new(type, rshape)
        off = 0
        ps.each_with_index do |p, i|
          next if lens[i] == 0
          idx = [nil] * r.ndim
          idx[axis] = off...(off + lens[i])
          r[*idx] = p[1]
          off += lens[i]
        end
        text = "meld(axis: #{axis}, #{CArray.data_type_name(type)}, lens #{lens.inspect}, #{shape.inspect})"
        rebuild = -> { CArray.meld(*arrays, axis: axis) }
      end
      text += " [#{ps.map { |p| p[2] }.join(', ')}]"
      return [v, r, arrays, text, rebuild, ps.any? { |p| p[3] }]
    end

    # Up to two views in a row: [lambda, text].  Each is chosen against the
    # shape it will see.
    def view_chain (shape)
      steps = []
      s = shape.dup
      int(3).times do
        break if s.empty? or s.include?(0)
        case int(6)
        when 0
          idx = s.map do |d|
            case int(4)
            when 0 then nil
            when 1 then a = int(d); a..(a + int(d - a))
            when 2
              a = int(d)
              st = ( d - a >= 2 and chance(0.5) ) ? 2 : 1
              [a, 1 + int((d - a + st - 1) / st), st]
            else int(d)
            end
          end
          idx[int(s.size)] = nil if idx.all? { |x| x.is_a?(Integer) }
          steps << [->(x) { x[*idx] }, "[#{idx.map(&:inspect).join(', ')}]"]
          s = idx.each_with_index.filter_map do |x, i|
            case x
            when nil   then s[i]
            when Range then x.size
            when Array then x[1]
            end
          end
        when 1
          next if s.size < 2
          perm = (0...s.size).to_a.shuffle(random: @r)
          steps << [->(x) { x.transpose(*perm) }, "transpose(#{perm.join(', ')})"]
          s = perm.map { |i| s[i] }
        when 2
          ax = int(s.size)
          steps << [->(x) { x.flip(ax) }, "flip(#{ax})"]
        when 3
          n = s.inject(:*)
          a = int(n)
          b = a + int(n - a)
          steps << [->(x) { x.reshape(n)[a..b] }, "reshape(#{n})[#{a}..#{b}]"]
          s = [b - a + 1]
        when 4
          ax = int(s.size)
          sel = (0...(1 + int(s[ax] + 1))).map { int(s[ax]) }
          idx = [nil] * s.size
          idx[ax] = CA_INT64(sel)
          steps << [->(x) { x[*idx] },
                    "[#{idx.map { |y| y.is_a?(CArray) ? "CA_INT64(#{y.to_a})" : y.inspect }.join(', ')}]"]
          s[ax] = sel.size
        when 5
          next if s.size < 2
          f = s.dup
          s = [f.shift * f.shift] + f
          shape2 = s.dup
          steps << [->(x) { x.reshape(*shape2) }, "reshape(#{shape2.join(', ')})"]
        end
      end
      return [->(x) { steps.inject(x) { |y, st| st[0].(y) } },
              steps.map { |st| st[1] }.join(".")]
    end

    def self.answer (x)
      return x.is_a?(CArray) ? x.to_a : x
    end

    READS = [
      ["to_a",         ->(x) { x.to_a }],
      ["copy",         ->(x) { x.copy.to_a }],
      ["is_masked",    ->(x) { x.is_masked.to_a }],
      ["count_masked", ->(x) { x.count_masked }],
      ["sum",          ->(x) { x.sum }],
      ["min",          ->(x) { x.min }],
      ["max",          ->(x) { x.max }],
      ["sort",         ->(x) { x.reshape(x.elements).sort.to_a }],
    ]

    AXIS_READS = [
      ["sum",          ->(x, a) { answer(x.sum(axis: a)) }],
      ["min",          ->(x, a) { answer(x.min(axis: a)) }],
      ["max",          ->(x, a) { answer(x.max(axis: a)) }],
      ["mean",         ->(x, a) { answer(x.mean(axis: a)) }],
      ["count_masked", ->(x, a) { answer(x.count_masked(axis: a)) }],
      ["median",       ->(x, a) { answer(x.median(axis: a)) }],
      ["sort",         ->(x, a) { x.sort(axis: a).to_a }],
      ["cumsum",       ->(x, a) { answer(x.cumsum(axis: a)) }],
      ["each_slab",    ->(x, a) { r = []; x.each_slab(axis: a) { |s| r << s.to_a }; r }],
    ]

    def read_op (shape)
      if not shape.empty? and chance(0.5)
        ax = int(shape.size)
        name, f = pick(AXIS_READS)
        return [->(x) { f.(x, ax) }, "#{name}(axis: #{ax})"]
      elsif not shape.empty? and not shape.include?(0) and chance(0.2)
        idx = shape.map { |d| int(d) }
        return [->(x) { x[*idx] }, "[#{idx.join(', ')}]"]
      else
        name, f = pick(READS)
        return [f, name]
      end
    end

    def write_op (type)
      case int(10)
      when 0
        v = 1 + int(5)
        return [->(x) { x[] = v }, "[] = #{v}"]
      when 1
        vals = (0...7).map { 10 + int(9) }
        return [->(x) { x[] = CArray.int32(x.elements).seq.map! { |i| vals[i % 7] }
                                    .reshape(*x.shape).to_type(x.data_type) },
                "[] = array"]
      when 2
        c = 1 + int(6)
        return [->(x) { x[x > c] = 0 }, "[x > #{c}] = 0"]
      when 3
        c = 1 + int(6)
        return [->(x) { x[x.eq(c)] = UNDEF }, "[x.eq(#{c})] = UNDEF"]
      when 4
        return write_op(type) if type == CA_OBJECT or type == CA_UINT8
        return [->(x) { x.add!(1) }, "add!(1)"]
      when 5
        return [->(x) { x.map! { |e| e.is_a?(Numeric) ? e * 2 : e } }, "map! { e * 2 }"]
      when 6
        return [->(x) { x[] = UNDEF }, "[] = UNDEF"]
      when 7
        return [->(x) { x.fill(UNDEF) }, "fill(UNDEF)"]
      when 8
        c = 1 + int(6)
        return [->(x) { x[:gt, c] = UNDEF }, "[:gt, #{c}] = UNDEF"]
      else
        v = 1 + int(5)
        return [->(x) { x.unmask(v) }, "unmask(#{v})"]
      end
    end
  end

  module_function

  def run (f, x)
    return [:ok, f.(x)]
  rescue Exception => e
    raise if e.is_a?(Interrupt) or e.is_a?(NoMemoryError)
    return [:raise, e.class, e.message]
  end

  def same (a, b)
    return false if [a, b].any? { |x| x[0] == :raise and x[2].include?("[BUG]") }
    return ( a[0] == b[0] and a[1] == b[1] ) if a[0] == :raise or b[0] == :raise
    return norm(a[1]) == norm(b[1])
  end

  # NaN equals NaN.
  def norm (v)
    case v
    when Array  then return v.map { |e| norm(e) }
    when Float  then return v.nan? ? :nan : v
    when CArray then return norm(v.to_a)
    else             return v
    end
  end

  def show (a)
    s = ( a[0] == :raise ) ? "raise #{a[1]}: #{a[2]}" : a[1].inspect
    return ( s.size > 300 ) ? s[0, 300] + "..." : s
  end

  def snapshot (parents)
    return parents.map { |p| run(->(x) { x.to_a }, p) }
  end

  # Case c of the given seed.  Returns nil when V and R agree, otherwise
  # [what was done, V's answer, R's answer].
  def check (seed, c)
    g = Gen.new(seed * 1_000_003 + c)
    writable = g.chance(0.45)
    v, r, parents, text, rebuild, restricted = g.subject(writable)
    chain, ctext = g.view_chain(r.shape)
    had_mask = parents.map(&:has_mask?)
    before = snapshot(parents)
    if writable
      op, otext = g.write_op(r.data_type)
      head = "case #{c}: #{text} .#{ctext} #{otext}"
      a = run(->(x) { op.(chain.(x)); nil }, v)
      b = run(->(x) { op.(chain.(x)); nil }, r)
      if a[0] == :raise
        unless before.zip(snapshot(parents)).all? { |x, y| same(x, y) }
          return [head, "#{show(a)}, and the refused write changed a parent", show(b)]
        end
        return nil if b[0] == :ok and restricted and REFUSAL =~ a[2] and not a[2].include?("[BUG]")
        return nil if b[0] == :raise and a[1] == b[1] and not a[2].include?("[BUG]")
        return [head, show(a), show(b)]
      end
      return [head, show(a), show(b)] if b[0] == :raise
      back = run(->(x) { x.to_a }, rebuild.())
      ref  = run(->(x) { x.to_a }, r)
      return same(back, ref) ? nil : [head, show(back), show(ref)]
    else
      shape = chain.(r).shape rescue r.shape
      op, otext = g.read_op(shape)
      head = "case #{c}: #{text} .#{ctext} .#{otext}"
      a = run(->(x) { op.(chain.(x)) }, v)
      b = run(->(x) { op.(chain.(x)) }, r)
      return [head, show(a), show(b)] unless same(a, b)
      after = snapshot(parents)
      changed = before.each_index.reject { |i| same(before[i], after[i]) }
      return [head, "the read changed parents #{changed}", ""] unless changed.empty?
      grew = parents.each_index.select { |i| not had_mask[i] and parents[i].has_mask? }
      return [head, "the read gave parents #{grew} a mask", ""] unless grew.empty?
      return nil
    end
  end

end

if $0 == __FILE__
  cases = (ARGV[0] || 2000).to_i
  seed  = (ARGV[1] || 1).to_i
  list  = ENV["ONLY"] ? [ENV["ONLY"].to_i] : (0...cases).to_a
  batch = (ENV["FORK"] || 0).to_i
  fails = []

  run_batch = lambda do |cs|
    rd, wr = IO.pipe
    pid = fork do
      rd.close
      cs.each { |c| Marshal.dump([c, StackMeldCases.check(seed, c)], wr) }
      wr.close
      exit! 0
    end
    wr.close
    out = []
    begin
      loop { out << Marshal.load(rd) }
    rescue EOFError
    end
    rd.close
    Process.wait(pid)
    [out, $?.success?]
  end

  if batch > 0
    list.each_slice(batch) do |cs|
      out, ok = run_batch.(cs)
      out.each { |_, f| fails << f if f }
      next if ok
      rest = cs - out.map(&:first)
      fails << ["case #{rest.first}: the process died", "", ""]
      rest.drop(1).each do |c|
        o, k = run_batch.([c])
        o.each { |_, f| fails << f if f }
        fails << ["case #{c}: the process died", "", ""] unless k
      end
    end
  else
    list.each { |c| f = StackMeldCases.check(seed, c); fails << f if f }
  end

  route = "CARRAY_GENERAL_PATH=#{ENV['CARRAY_GENERAL_PATH'] || 0}"
  route += " CARRAY_SHORTCUTS_OFF=#{ENV['CARRAY_SHORTCUTS_OFF']}" if ENV["CARRAY_SHORTCUTS_OFF"]
  puts "#{route}  seed #{seed}  cases #{list.size}  mismatches #{fails.size}"
  fails.first((ENV["SHOW"] || 40).to_i).each do |f|
    puts "-" * 70
    puts f[0]
    puts "  view   : #{f[1]}"
    puts "  entity : #{f[2]}"
  end
  exit( fails.empty? ? 0 : 1 )
end
