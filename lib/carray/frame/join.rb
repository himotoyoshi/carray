# CAFrame join (memo §5, §11.7, §13.3).
#
# Join is a thin delegation to landed addressing primitives: the join key
# yields an address array (locate_addr for a row-preserving left lookup,
# align_addr for symmetric set alignment), and each column is gathered by
# +project+ (length-preserving, miss -> UNDEF, Face-lift, read-only safe).
# The frame layer just distributes that address to every column.

require "carray/methods/is_in"   # promote_value_set, for align's Array reference
require "carray/methods/locate_addr"   # nearest_refuse_bytes, for join_asof

class CAFrame
  # Default disambiguation for non-key columns present on both sides (§12-C):
  # left gets "_left", right gets "_right". +_left+/+_right+ read clearer than
  # pandas' +_x+/+_y+ for the target audience.
  DEFAULT_JOIN_SUFFIXES = ["_left", "_right"].freeze
  Ractor.make_shareable(DEFAULT_JOIN_SUFFIXES)
  private_constant :DEFAULT_JOIN_SUFFIXES

  # Join +other+ on a shared key column, as SQL joins: each pair of a left
  # row and a right row with the same key gives one row, so a key on k left
  # rows and m right rows gives k * m rows.  A masked key matches nothing.
  #
  #   how: :left  (default) — every pair, and each left row with no match
  #                           once, its right columns UNDEF.
  #   how: :inner — every pair.
  #   how: :right — every pair, and each right row with no match once.
  #   how: :outer — every pair, each unmatched left row, then each unmatched
  #                 right row.
  #
  # Rows come in left-row order (right-row order for :right), the pairs of
  # one row in the other side's order.  The left columns are views of this
  # frame's, picked by row, wherever every row comes from the left (:left,
  # :inner); the right columns are gathered into new arrays.
  #
  # A non-key column present on both sides collides. The key column (+on+) is
  # kept once, never suffixed. By default the collision is resolved by suffixing
  # both sides (+suffixes: ["_left", "_right"]+); pass a 2-element array to pick
  # meaningful names up front (+["_obs", "_fcst"]+), or +suffixes: false+ to
  # raise instead. Rename afterward with +rename+ if needed (§12-C).
  #
  # +on:+ may name several columns, as an Array: rows then match when every
  # key column matches, and a row with any key cell masked matches nothing.
  #
  #   obs.join(fcst, on: ["station", "date"])
  #
  # Two modes filter this frame's rows by +other+ instead of pairing them:
  #
  #   how: :semi — the rows whose key some row of +other+ has.
  #   how: :anti — the rows whose key no row of +other+ has.
  #
  # Each row appears at most once, in this frame's order, and no column of
  # +other+ is added, so no name collides and +suffixes:+ is refused.  A row
  # with a masked key matches nothing: :semi drops it and :anti keeps it.
  # The result shares this frame's columns and index, as +filter+'s does.
  #
  #   obs.join(stations, on: "station", how: :anti)   # stations not listed
  def join(other, on:, how: :left, suffixes: DEFAULT_JOIN_SUFFIXES)
    unless %i[left inner outer right semi anti].include?(how)
      raise ArgumentError, "unknown join mode #{how.inspect}"
    end
    if (how == :semi || how == :anti) && !suffixes.equal?(DEFAULT_JOIN_SUFFIXES)
      raise ArgumentError, "join: how: #{how.inspect} adds no column of the other frame, so suffixes: does not apply"
    end
    names = join_key_names(on, "join", "on:")
    lkeys = names.map { |name| key_column(name, "join") }
    rkeys = names.map { |name| other.__send__(:key_column, name, "join") }
    join_check_key_widths(names, lkeys, rkeys, "join")
    return join_filter(lkeys, rkeys, how) if how == :semi || how == :anti

    plan = join_name_plan(other, names, suffixes)
    join_pairs(other, names, lkeys, rkeys, how, plan)
  end

  # As-of (nearest-key) left join for irregular series (memo §11.7). Each
  # left row is matched to the nearest +other+ row by +on+ via
  # locate_nearest_addr (the per-row, row-preserving counterpart of
  # align_nearest_addr); +direction:+ follows CArray (:floor = most recent
  # at-or-before, :ceil = next, :round = nearest), and rows with no match
  # in that direction or beyond +tolerance:+ come back UNDEF. +tolerance:+
  # is a number for a numeric key and a duration for a time key
  # ("10 minutes", or a CATimedelta value). Same wiring as the left join,
  # only the address primitive differs.
  #
  # +by:+ names columns that must match exactly, one name or an Array: each
  # left row is matched to the nearest row among the rows of +other+ with
  # the same +by+ values.  A row with a masked +by+ cell matches nothing.
  #
  #   obs.join_asof(radar, on: "time", by: "station", tolerance: "10 minutes")
  def join_asof(other, on:, by: nil, direction: :floor, tolerance: nil, suffixes: DEFAULT_JOIN_SUFFIXES)
    on    = column_key(on, "join_asof")
    exact = by.nil? ? [] : join_key_names(by, "join_asof", "by:")
    if exact.include?(on)
      raise ArgumentError, "join_asof: #{on.inspect} is the on: key; by: names the others"
    end
    plan = join_name_plan(other, [on, *exact], suffixes)
    lkey = key_column(on, "join_asof")
    rkey = other.__send__(:key_column, on, "join_asof")
    [lkey, rkey].each do |key|
      key.__send__(:nearest_refuse_bytes, key, "join_asof: the on: key #{on.inspect}",
                   "join on it exactly with join")
    end
    addr = if exact.empty?
             lkey.locate_nearest_addr(rkey, direction: direction, tolerance: tolerance)
           else
             lexact = exact.map { |name| key_column(name, "join_asof") }
             rexact = exact.map { |name| other.__send__(:key_column, name, "join_asof") }
             join_check_key_widths(exact, lexact, rexact, "join_asof")
             _, lcode, rcode, k = join_codes(lexact, rexact)
             join_asof_by(lkey, rkey, lcode, rcode, k, direction, tolerance)
           end
    join_by_addr(other, [on, *exact], addr, plan)
  end

  # Conform every column to an externally supplied reference key set (the
  # asymmetric sibling of +join+; pandas +reindex+). Given a +reference+ array
  # of key values, each column is gathered onto it by exact key match
  # (+locate_addr+): the aligned key column (or index) becomes the reference
  # itself, and a reference key absent from the source comes back UNDEF in
  # every other column.
  #
  # CAFrame measures no interval and generates nothing -- the caller owns the
  # reference. This is the primitive for reindexing to a caller-built axis
  # (e.g. a complete 10-minute time grid): supply that axis as +reference+ and
  # the gaps fill with UNDEF rows carrying only the reference key.
  #
  #   df.align("time", reftime)   # reftime = a CArray of reference key values
  #
  # +key+ may be a column name or the index axis name. +reference+ is a CArray
  # or an Array; its keys are matched against the source key by value.  An
  # Array is read as values of the key's kind, as +is_in+ reads one: numbers
  # against a numeric key, Time / Date / String instants against a time key.
  def align(key, reference)
    key = column_key(key, "align")
    on_index = !@columns.key?(key) && @axis_name == key && @index
    keys = key_column(key, "align")
    # An Array reference is read as values of the key's kind, as is_in reads
    # one: 1 and 2.5 against a float key are numbers, and Time or String
    # values against a time key are instants.
    ref = reference.is_a?(CArray) ? reference : keys.send(:promote_value_set, reference)[1]
    unless ref.ndim == 1
      raise ArgumentError,
            "align: the reference has shape #{ref.shape.inspect}; give one key value per row of the result"
    end
    addr = ref.locate_addr(keys)

    cols = {}
    column_names.each { |name| cols[name] = project_rows(self[name], addr) }
    if on_index
      CAFrame.new(cols, axis_name: key, index: ref)
    else
      cols[key] = ref
      CAFrame.new(cols, axis_name: @axis_name,
                        index: @index && project_rows(@index, addr))
    end
  end

  # Paste +other+'s columns beside this frame's, matched by **row position**
  # (memo §12-C) — a keyless column merge (the column-direction counterpart of
  # the row-stacking +concat+, and the positional counterpart of the key-aligned
  # +join+; named after the UNIX +paste+). Both frames must have the same
  # +nrow+; rows are assumed to already correspond (no key alignment, consistent
  # with the no-implicit-align stance). Colliding column names are disambiguated
  # by the same policy as +join+ (default suffix +_left+/+_right+, +suffixes:+ to
  # override, +suffixes: false+ to raise). This frame's index is kept; +other+'s
  # index, if any, is not carried (only its columns are pasted). Returns a new
  # frame.
  #
  #   obs.paste(fcst)                          # side by side, same rows
  #   obs.paste(fcst, suffixes: ["_obs", "_fcst"])
  def paste(other, suffixes: DEFAULT_JOIN_SUFFIXES)
    CAFrame.paste(self, other, suffixes: suffixes)
  end

  # Paste N frames side by side by row position (symmetric N-ary sibling of
  # the instance +#paste+; see the instance verb's docstring for the pair
  # semantics).  All frames must have the same +nrow+.  The result's
  # +axis_name+ and +index+ come from the first frame (peers, but a base is
  # needed for the index).  Column names that appear in more than one frame
  # are colliding — pass +suffixes:+ as an Array of exactly K strings (one
  # per input frame) to disambiguate them; otherwise the collision raises.
  #
  #   CAFrame.paste(obs, fcst)
  #   CAFrame.paste(obs, ecmwf, gfs, suffixes: ["_obs", "_ecmwf", "_gfs"])
  #   CAFrame.paste([obs, fcst])                              # Array is accepted too
  def self.paste(*frames, suffixes: DEFAULT_JOIN_SUFFIXES)
    frames = frames.flatten
    raise ArgumentError, "paste requires at least one frame" if frames.empty?
    unless frames.all? { |f| f.is_a?(CAFrame) }
      raise ArgumentError, "paste expects CAFrame arguments"
    end
    first = frames.first
    nrow  = first.nrow
    frames.each_with_index do |f, i|
      next if i.zero?
      unless f.nrow == nrow
        raise ArgumentError,
              "paste: row-count mismatch (frame #{i}: #{f.nrow} vs #{nrow}); " \
              "use join for key alignment"
      end
    end

    # Detect columns that appear in 2+ frames (collisions across the K inputs).
    name_count = Hash.new(0)
    frames.each { |f| f.column_names.each { |name| name_count[name] += 1 } }
    # The first frame's index keeps its name as the result's row axis, so a
    # column of that name collides with it as with a column.
    name_count[first.axis_name] += 1 if first.index
    collisions = name_count.select { |_, n| n > 1 }.keys

    if collisions.any?
      if suffixes == false
        raise ArgumentError,
              "paste column name collision: #{collisions.inspect} " \
              "(pass suffixes: [\"_a\", \"_b\", ...] with one entry per frame, " \
              "or rename first)"
      end
      # For the 2-frame case DEFAULT_JOIN_SUFFIXES ("_left", "_right") works
      # as-is; for K > 2 the caller must pass a K-length Array (or use the
      # pair-only default indirectly via the instance method).
      unless suffixes.is_a?(Array) && suffixes.size == frames.size &&
             suffixes.all? { |s| s.is_a?(String) }
        raise ArgumentError,
              "paste: suffixes must be an Array of #{frames.size} Strings " \
              "(one per frame), got #{suffixes.inspect}"
      end
    end

    cols = {}
    frames.each_with_index do |f, i|
      f.column_names.each do |name|
        key = collisions.include?(name) ? "#{name}#{suffixes[i]}" : name
        if cols.key?(key)
          raise ArgumentError,
                "paste: column name #{key.inspect} produced twice " \
                "(collision after suffix from frame #{i})"
        end
        cols[key] = f[name]
      end
    end
    new(cols, axis_name: first.axis_name, index: first.index)
  end

  # A fixlen key holds a cell-width blob, so a left key and a right key of
  # different widths share no value.  Refuse it here, naming the column,
  # rather than from inside the set operation the join runs.
  private def join_check_key_widths(names, lkeys, rkeys, verb)
    names.zip(lkeys, rkeys) do |name, l, r|
      next unless l.data_type == CA_FIXLEN && r.data_type == CA_FIXLEN
      next if l.face? || r.face? || l.bytes == r.bytes
      raise CArray::DataTypeError,
            "#{verb}: the key #{name.inspect} is fixlen #{l.bytes} bytes wide on the left " \
            "and #{r.bytes} on the right; a fixlen value is a cell-width blob, so the widths must match"
    end
  end

  # The key column names of a join: one name, or an Array of names.
  private def join_key_names(on, verb, option)
    names = on.is_a?(Array) ? on : [on]
    raise ArgumentError, "#{verb}: #{option} names no key column" if names.empty?
    CAFrame.__send__(:refuse_repeated_names, names.map { |name| column_key(name, verb) },
                     verb, "#{option} names")
  end

  # Codes for the rows of both sides of a join on +lkeys+ / +rkeys+ (one
  # array per key column): equal codes for equal keys, in 0...k, and none
  # for a row with a masked key cell.  Each key column gets a code in one
  # set of distinct values of both sides, compared as the lookups compare
  # them (type, unit and width reconciled).  With several key columns a
  # row's key is the tuple of its codes, coded again one column at a time
  # so the number stays below the row count.  Returns [parts, lcode, rcode,
  # k], parts holding each column's [distinct values, left codes, right
  # codes].
  private def join_codes(lkeys, rkeys)
    parts = lkeys.zip(rkeys).map do |lkey, rkey|
      common = CArray.align_addr(lkey, rkey, join: :outer)[0]
      [common, lkey.locate_addr(common), rkey.locate_addr(common)]
    end
    _, lcode, rcode = parts[0]
    k = parts[0][0].elements
    parts.drop(1).each do |common, lc, rc|
      # keys: the two frames are coded on the values they share, which
      # CACategorical.from_keys (one side's own values) cannot give
      lt = lcode * common.elements + lc
      rt = rcode * common.elements + rc
      tuples = CArray.align_addr(lt, rt, join: :outer)[0]
      lcode, rcode, k = lt.locate_addr(tuples), rt.locate_addr(tuples), tuples.elements
    end
    [parts, lcode, rcode, k]
  end

  # The rows of a :semi or :anti join: whether each row's key code occurs
  # among the other side's codes.  A row without a code (a masked key cell)
  # has no match.
  private def join_filter(lkeys, rkeys, how)
    _, lcode, rcode, k = join_codes(lkeys, rkeys)
    matched = if k == 0
                CArray.boolean(nrow).fill(false)
              else
                rcode.bincount(length: k).project(lcode).strip_mask(0).gt(0)
              end
    select_rows(how == :semi ? matched : matched.not)
  end

  # The other side's row for each left row of an as-of join with exact
  # keys: the nearest by +lkey+ / +rkey+ among the right rows with the
  # same code, as locate_nearest_addr finds it within one group.
  #
  # All groups are searched at once.  The right rows are sorted by (code,
  # key, row); sorting the left keys in among them by (code, key) counts,
  # for each left row, the right rows of its group below it, and the
  # nearest is one of the two right rows on either side of that count.
  private def join_asof_by(lkey, rkey, lcode, rcode, k, direction, tolerance)
    # direction: and tolerance: are checked here, on no rows, whether or
    # not any group is in both frames.
    lkey[0...0].locate_nearest_addr(rkey[0...0], direction: direction, tolerance: tolerance)
    limit = tolerance && CArray::DistanceLimit.read(tolerance, lkey, "tolerance:")
    addr = CArray.int64(lkey.elements).fill(UNDEF)

    # The right rows that can be found: a code, and a key that is present
    # and not NaN.  Each group's rows in key order, a tie in row order.
    rvalid = asof_searchable(rkey, rcode)
    rrows = CArray.int64(rkey.elements).seq[rvalid].copy
    return addr if rrows.elements == 0
    rrows = rrows.project(CArray.sort_addr(rcode.project(rrows), rkey.project(rrows), rrows))
    lvalid = asof_searchable(lkey, lcode)
    lrows = CArray.int64(lkey.elements).seq[lvalid].copy
    return addr if lrows.elements == 0

    rk, qk = lkey.__send__(:nearest_keys, rkey.project(rrows), lkey.project(lrows))
    rc = rcode.project(rrows).int64
    qc = lcode.project(lrows).int64
    n = rrows.elements
    gcount = rc.bincount(length: k).int64
    gstart = gcount.cumsum.int64 - gcount

    # How many right rows of its group each left row has below it (at or
    # below when +inclusive+): the left keys sorted in among the right
    # ones, a tie putting the right one first when it counts.
    below = lambda do |inclusive|
      tag = CArray.int8(n + qk.elements)
      tag[0...n] = inclusive ? 0 : 1
      tag[n..-1] = inclusive ? 1 : 0
      perm = CArray.sort_addr(CArray.concatenate([rc, qc]), CArray.concatenate([rk, qk]), tag)
      seen = perm.lt(n).cumsum.int64
      query = perm.ge(n)
      count = CArray.int64(qk.elements)
      count[perm[query] - n] = seen[query]
      count - gstart.project(qc)
    end

    size = gcount.project(qc)
    local =
      case direction
      when :floor then below.(true) - 1
      when :ceil  then below.(false)
      when :round
        lt = below.(false)
        start = gstart.project(qc)
        has_lo = lt.gt(0)
        has_hi = lt.lt(size)
        lo = rk.project((start + lt - 1).tap { |a| a[has_lo.not] = UNDEF })
        hi = rk.project((start + lt).tap { |a| a[has_hi.not] = UNDEF })
        # an exact match takes its first reference; otherwise the nearer
        # neighbour, the upper one on a tie
        upper = (hi - qk).le(qk - lo).strip_mask(false)
        upper[has_lo.not] = true
        upper[has_hi.not] = false
        upper[hi.eq(qk).strip_mask(false)] = true
        lt - 1 + upper.int64
      end
    local[local.lt(0) | local.ge(size)] = UNDEF
    found = rrows.project(gstart.project(qc) + local)
    if limit
      dist = (rkey.project(found) - lkey.project(lrows)).abs
      found[dist > limit] = UNDEF
    end
    addr[lrows] = found
    addr
  end

  # The rows of a key that an as-of search can place: a group code, and a
  # key cell that is neither masked nor NaN.
  private def asof_searchable(key, code)
    ok = code.is_not_masked.strip_mask(false)
    ok &= key.is_not_masked.strip_mask(false) if key.has_mask?
    ok &= key.is_nan.strip_mask(false).not if key.float?
    ok
  end

  # The left index keeps its name as the result's row axis, so a right
  # column of that name collides with it as with a left column: it takes
  # the right suffix, and there is no left column to take the left one.
  private def join_name_plan(other, names, suffixes)
    taken = @index ? column_names | [@axis_name] : column_names
    collisions = (taken & other.column_names) - names
    return { collisions: [], lsuf: nil, rsuf: nil } if collisions.empty?

    if suffixes == false
      raise ArgumentError,
            "join column name collision: #{collisions.inspect} " \
            "(pass suffixes: [\"_l\", \"_r\"] to disambiguate, or rename first)"
    end
    unless suffixes.is_a?(Array) && suffixes.size == 2 && suffixes.all? { |s| s.is_a?(String) }
      raise ArgumentError,
            "suffixes must be false or a 2-element array of Strings, got #{suffixes.inspect}"
    end
    { collisions: collisions, lsuf: suffixes[0], rsuf: suffixes[1] }
  end

  private def join_name(name, suffix, plan)
    plan[:collisions].include?(name) ? "#{name}#{suffix}" : name
  end

  # names-check: the output is checked as it is built, a column at a time
  private def put_join_column(cols, name, col)
    if cols.key?(name)
      raise ArgumentError,
            "join produces a duplicate column #{name.inspect} after suffixing; " \
            "rename a column first or pass different suffixes"
    end
    cols[name] = col
  end

  private def join_by_addr(other, names, addr, plan)
    cols = {}
    column_names.each { |name| put_join_column(cols, join_name(name, plan[:lsuf], plan), self[name]) }
    other.column_names.each do |name|
      next if names.include?(name)
      put_join_column(cols, join_name(name, plan[:rsuf], plan), project_rows(other[name], addr))
    end
    CAFrame.new(cols, axis_name: @axis_name, index: @index)
  end

  # The rows of a key join: li / ri are the left / right row of each result
  # row, UNDEF on the side a row has no match on.
  private def join_pairs(other, names, lkeys, rkeys, how, plan)
    parts, lcode, rcode, k = join_codes(lkeys, rkeys)
    extra = nil
    if how == :right
      ri, li = join_expand(rcode, lcode, k, true)
    else
      li, ri = join_expand(lcode, rcode, k, how != :inner)
      if how == :outer
        lcount = lcode.bincount(length: k)
        alone  = rcode.is_masked | lcount.project(rcode).strip_mask(0).eq(0)
        alone  = alone.strip_mask(true)
        extra  = CArray.int64(rcode.elements).seq[alone]
        if extra.elements > 0
          undef_rows = CArray.int64(extra.elements).fill(UNDEF)
          li = CArray.concatenate([li, undef_rows])
          ri = CArray.concatenate([ri, extra])
        else
          extra = nil
        end
      end
    end
    every_left = how == :left || how == :inner
    identity   = every_left && li.elements == nrow &&
                 (nrow == 0 || li.eq(CArray.int64(nrow).seq).all)
    rows = { li: li, ri: ri, extra: extra, how: how, every_left: every_left, identity: identity }
    cols = {}
    column_names.each do |name|
      j = names.index(name)
      col = if j                 then joined_key(j, parts, lkeys, rkeys, rows)
            elsif identity       then self[name]
            elsif every_left     then self[name][li, *([nil] * (self[name].ndim - 1))]
            else                      project_rows(self[name], li)
            end
      name = join_name(name, plan[:lsuf], plan) unless j
      put_join_column(cols, name, col)
    end
    other.column_names.each do |name|
      next if names.include?(name)
      put_join_column(cols, join_name(name, plan[:rsuf], plan), project_rows(other[name], ri))
    end
    # A key that is the left index is the result's index, as a key column
    # is a column of it.
    ij = @index && !@columns.key?(@axis_name) ? names.index(@axis_name) : nil
    new_index = if @index.nil?  then nil
                elsif ij        then joined_key(ij, parts, lkeys, rkeys, rows)
                elsif identity  then @index
                elsif every_left then @index[li]
                else                  project_rows(@index, li)
                end
    CAFrame.new(cols, axis_name: @axis_name, index: new_index)
  end

  # The key +j+ of each row of a key join: the left key on the rows from the
  # left, and on an unmatched right row of a right or outer join the right
  # key, so a key is kept once and is never UNDEF where a row has one.
  private def joined_key(j, parts, lkeys, rkeys, rows)
    li, ri = rows[:li], rows[:ri]
    return lkeys[j] if rows[:identity]
    return lkeys[j][li] if rows[:every_left]
    return project_rows(rkeys[j], ri) if rows[:how] == :right
    common, lc, rc = parts[j]
    extra = rows[:extra]
    code = if extra
             nleft = li.elements - extra.elements
             CArray.concatenate([lc.project(li[0...nleft]), rc.project(extra)])
           else
             lc.project(li)
           end
    # The key takes the attributes both sides show alike, as a
    # concatenation of the two would.
    shared = CArray.__send__(:attrs_shared_by, [lkeys[j], rkeys[j]])
    key = joined_key_kind(common.project(code), lkeys[j], rkeys[j])
    key.tap { |c| c.set_attrs(shared) unless shared.empty? }
  end

  # The kind of a key column holding values of both sides, the same
  # whichever side is the receiver: a Face both sides share stays (a
  # categorical with the labels of both, the left's first), and keys of
  # two different Faces, or of a Face and a plain array, are objects.
  private def joined_key_kind(col, lkey, rkey)
    lface = lkey.face? ? lkey.class : nil
    rface = rkey.face? ? rkey.class : nil
    return col if lface.nil? && rface.nil?
    if lface == rface
      return col unless lface <= CACategorical
      values = CArray.object(col.elements)
      values[] = col.to_a
      return values.categorize(labels: lkey.labels | rkey.labels)
    end
    return col if !col.face? && col.object?
    CArray.object(col.elements).tap { |o| o[] = col.to_a }
  end

  # Pairs a side's rows (codes +acode+) with the other side's (+bcode+), in
  # a-row order and, for one a-row, in b-row order.  An a-row with no match
  # comes once with no b-row when +keep_alone+.  Returns [ai, bi].
  private def join_expand(acode, bcode, k, keep_alone)
    na, nb = acode.elements, bcode.elements
    # b's rows by code, each code's rows in b-row order.
    border = CArray.sort_addr(bcode, CArray.int64(nb).seq)
    bcount = bcode.bincount(length: k).int64
    bstart = bcount.cumsum.int64 - bcount
    matches = bcount.project(acode).strip_mask(0)
    reps = keep_alone ? matches.pmax(1) : matches
    total = reps.sum.to_i
    return [CArray.int64(0), CArray.int64(0)] if total == 0
    # Each a-row repeated reps times: mark where each run starts and count.
    rows  = CArray.int64(na).seq[reps.gt(0)]
    first = (reps.cumsum.int64 - reps)[reps.gt(0)]
    mark  = CArray.int64(total).fill(0)
    mark[first] = 1
    run   = mark.cumsum.int64 - 1
    ai    = rows[run]
    j     = CArray.int64(total).seq - first[run]
    bi    = CArray.int64(total).fill(UNDEF)
    hit   = matches.project(ai).gt(0)
    if hit.any
      bi[hit] = border.project(bstart.project(acode.project(ai[hit])) + j[hit])
    end
    [ai, bi]
  end

  private def project_rows(col, addr)
    return col.project(addr) if col.ndim == 1
    trailing = col.shape[1..]
    t = trailing.inject(1, :*)
    n = addr.shape[0]
    flat = addr.reshape(n, 1) * t + CArray.int64(t).seq.reshape(1, t)
    col.project(flat).reshape(n, *trailing)
  end
end
