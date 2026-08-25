# CAFrame join (memo §5, §11.7, §13.3).
#
# Join is a thin delegation to landed addressing primitives: the join key
# yields an address array (locate_addr for a row-preserving left lookup,
# align_addr for symmetric set alignment), and each column is gathered by
# +project+ (length-preserving, miss -> UNDEF, Face-lift, read-only safe).
# The frame layer just distributes that address to every column.

class CAFrame
  # Default disambiguation for non-key columns present on both sides (§12-C):
  # left gets "_left", right gets "_right". +_left+/+_right+ read clearer than
  # pandas' +_x+/+_y+ for the target audience.
  DEFAULT_JOIN_SUFFIXES = ["_left", "_right"].freeze
  private_constant :DEFAULT_JOIN_SUFFIXES

  # Join +other+ on a shared key column.
  #
  #   how: :left  (default) — keep all left rows; right columns gathered per
  #                           left row (locate_addr), misses become UNDEF.
  #   how: :inner/:outer/:right — set-align both key sets (align_addr) and
  #                           gather both sides; the aligned key values form
  #                           the +on+ column.
  #
  # A non-key column present on both sides collides. The key column (+on+) is
  # kept once, never suffixed. By default the collision is resolved by suffixing
  # both sides (+suffixes: ["_left", "_right"]+); pass a 2-element array to pick
  # meaningful names up front (+["_obs", "_fcst"]+), or +suffixes: false+ to
  # raise instead. Rename afterward with +rename+ if needed (§12-C).
  def join(other, on:, how: :left, suffixes: DEFAULT_JOIN_SUFFIXES)
    on   = on.to_s
    lkey = self[on]
    rkey = other[on]
    plan = join_name_plan(other, on, suffixes)

    case how
    when :left
      join_left(other, on, lkey, rkey, plan)
    when :inner, :outer, :right
      join_align(other, on, lkey, rkey, how, plan)
    else
      raise ArgumentError, "unknown join mode #{how.inspect}"
    end
  end

  # As-of (nearest-key) left join for irregular series (memo §11.7). Each
  # left row is matched to the nearest +other+ row by +on+ via
  # locate_nearest_addr (the per-row, row-preserving counterpart of
  # align_nearest_addr); +direction:+ follows CArray (:floor = most recent
  # at-or-before, :ceil = next, :round = nearest), and rows with no match
  # in range or beyond +tolerance:+ come back UNDEF. Same wiring as the left
  # join, only the address primitive differs.
  def join_asof(other, on:, direction: :floor, tolerance: nil, suffixes: DEFAULT_JOIN_SUFFIXES)
    on   = on.to_s
    plan = join_name_plan(other, on, suffixes)
    addr = self[on].locate_nearest_addr(other[on], direction: direction, tolerance: tolerance)
    join_by_addr(other, on, addr, plan)
  end

  # Conform every variable to an externally supplied reference key set (the
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
  # (or Array); its keys are matched against the source key by value, so their
  # data types must be comparable (a DateTime object key matches by eql?/hash).
  def align(key, reference)
    key = key.to_s
    ref = reference.is_a?(CArray) ? reference : reference.to_ca
    on_index = !@columns.key?(key) && @axis_name == key && @index
    addr = ref.locate_addr(on_index ? @index : self[key])

    cols = {}
    variable_names.each { |name| cols[name] = project_rows(self[name], addr) }
    if on_index
      CAFrame.new(cols, axis_name: key, index: ref)
    else
      cols[key] = ref
      CAFrame.new(cols, axis_name: @axis_name,
                        index: @index && project_rows(@index, addr))
    end
  end

  # Paste +other+'s variables beside this frame's, matched by **row position**
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
    frames.each { |f| f.variable_names.each { |name| name_count[name] += 1 } }
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
      f.variable_names.each do |name|
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

  private def join_name_plan(other, on, suffixes)
    collisions = (variable_names & other.variable_names) - [on]
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

  private def put_join_column(cols, name, col)
    if cols.key?(name)
      raise ArgumentError,
            "join produces a duplicate column #{name.inspect} after suffixing; " \
            "rename a column first or pass different suffixes"
    end
    cols[name] = col
  end

  private def join_left(other, on, lkey, rkey, plan)
    join_by_addr(other, on, lkey.locate_addr(rkey), plan)
  end

  private def join_by_addr(other, on, addr, plan)
    cols = {}
    variable_names.each { |name| put_join_column(cols, join_name(name, plan[:lsuf], plan), self[name]) }
    other.variable_names.each do |name|
      next if name == on
      put_join_column(cols, join_name(name, plan[:rsuf], plan), project_rows(other[name], addr))
    end
    CAFrame.new(cols, axis_name: @axis_name, index: @index)
  end

  private def join_align(other, on, lkey, rkey, how, plan)
    common, a_idx, b_idx = CArray.align_addr(lkey, rkey, join: how)
    cols = {}
    variable_names.each do |name|
      if name == on
        put_join_column(cols, on, common)
      else
        put_join_column(cols, join_name(name, plan[:lsuf], plan), project_rows(self[name], a_idx))
      end
    end
    other.variable_names.each do |name|
      next if name == on
      put_join_column(cols, join_name(name, plan[:rsuf], plan), project_rows(other[name], b_idx))
    end
    # Carry the left index the same way its columns are gathered (by a_idx),
    # so it stays consistent with the left join; rows with no left match
    # (outer/right) become UNDEF.
    new_index = @index && project_rows(@index, a_idx)
    CAFrame.new(cols, axis_name: @axis_name, index: new_index)
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
