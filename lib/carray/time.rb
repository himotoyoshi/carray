# lib/carray/time.rb
#
# Ruby surface for the CATime / CATimedelta Faces: construction
# entry points, arithmetic / comparison operators, reductions, and the
# pandas-style field accessors.
#
# CATime / CATimedelta construction entry points:
#   - `CATime.new(*shape, unit: :ns)` — new allocate + Face wrap
#   - `CATime.wrap(raw_int64, unit: :ns)` — zero-copy mask over existing entity (C side)
#   - `CArray#time(unit: :ns)` — instance-method Face-conversion sugar (= sugar over `.wrap`)
#   - Same pattern for CATimedelta
#
# Base epoch fixed to 1970-01-01 (Unix epoch).
# NetCDF CF convention (= reference time epoch) is delegated to external gems (timesteps etc.).

# Internal: unit-conversion algebra shared by CATime / CATimedelta
# (used by to_comparable to align a search query to the reference unit).
#
# The units split into two groups that are NOT inter-convertible by a fixed
# ratio: fixed-length (W/D/h/m/s/ms/.../as, ratios in seconds) and calendar
# (Y/M, ratio in months -- W and below are calendar-dependent in days).
# Within a group any pair is an exact integer ratio (coarse = fine * N), so a
# coarse->fine cast is lossless (multiply), and a fine->coarse cast is lossless
# only when every value is divisible by the divisor.
# Civil-date arithmetic on int64 CArrays: the calendar kernel every time
# grid is built on (Howard Hinnant's days<->civil algorithms, vectorized) plus
# the floor-division primitive they need -- CArray `/` truncates toward zero,
# and calendar math has to floor toward the past.  Internal to the time
# surface: nothing here is part of the public API.
module CATimeCivil
  module_function

  # Floored integer division of an int64 CArray by a positive Integer
  # (toward -inf; CArray `/` truncates toward zero).
  def floor_divide(a, b)
    q = a / b
    q - (a - q * b).lt(0)
  end

  # Vectorized Howard Hinnant civil-date algebra (proleptic Gregorian,
  # negative days supported).  days since the Unix epoch -> [year, month,
  # day] int64 CArrays.  Truncating division is what the algorithm assumes;
  # the only negative operand (the 400-year era) is pre-adjusted so
  # truncation behaves like floor.
  def civil_from_days(z)
    z   = z + 719468
    era = (z - 146096 * z.lt(0)) / 146097
    doe = z - era * 146097
    yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
    y   = yoe + era * 400
    doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    mp  = (5 * doy + 2) / 153
    d   = doy - (153 * mp + 2) / 5 + 1       # day of month, 1..31
    m   = mp + (3 - 12 * mp.ge(10))          # mp<10 ? +3 : -9
    [y + m.le(2), m, d]
  end

  # [year, month, day] int64 CArrays -> days since the Unix epoch.
  def days_from_civil(y, m, d)
    y   = y - m.le(2)
    era = (y - 399 * y.lt(0)) / 400
    yoe = y - era * 400
    doy = (153 * (m + (9 - 12 * m.gt(2))) + 2) / 5 + (d - 1)  # m>2 ? -3 : +9
    doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    era * 146097 + doe - 719468
  end
end

module CATimeUnitAlgebra
  # seconds per base unit (Rational)
  FIXED = {
    W: 604800r, D: 86400r, h: 3600r, m: 60r, s: 1r,
    ms: Rational(1, 10**3),  us: Rational(1, 10**6),  ns: Rational(1, 10**9),
    ps: Rational(1, 10**12), fs: Rational(1, 10**15), as: Rational(1, 10**18),
  }.freeze
  # months per base unit (Rational)
  CALENDAR = { Y: 12r, M: 1r }.freeze

  # Base units from finest to coarsest granularity.  Every fixed-length unit is
  # finer than every calendar unit (a week < a month), so this is a total
  # order used to pick the base that two operands both convert into exactly.
  GRANULARITY = %i[as fs ps ns us ms s m h D W M Y].freeze

  module_function

  # seconds- (fixed) or months- (calendar) per base tick.
  def base_ratio(base)
    FIXED[base] || CALENDAR[base]
  end

  # Normalize a unit spec (Resolution / Symbol / String) to a Resolution.
  # A bare Symbol / String routes through Resolution.parse (count-1 base).
  def res(u)
    u.is_a?(CATime::Resolution) ? u : CATime::Resolution.parse(u)
  end

  # Greatest common divisor of two positive Rationals (both in lowest terms).
  def rgcd(a, b)
    Rational(a.numerator.gcd(b.numerator), a.denominator.lcm(b.denominator))
  end

  # Whether two units are in the same group (both calendar or both fixed).
  def same_group?(u1, u2)
    CALENDAR.key?(res(u1).base) == CALENDAR.key?(res(u2).base)
  end

  # The common grid two same-group resolutions both convert into exactly: the
  # resolution whose tick is the gcd of the two ticks (finest common base +
  # the whole multiplier).  For equal resolutions this is the resolution
  # itself; for `(1,:D)` & `(1,:h)` it is `(1,:h)`; for `(5,:m)` & `(2,:m)` it
  # is `(1,:m)`.  Both operands are same-group (checked by the caller).
  def common(u1, u2)
    a  = res(u1); b = res(u2)
    fb = GRANULARITY.index(a.base) <= GRANULARITY.index(b.base) ? a.base : b.base
    g  = rgcd(a.tick_ratio, b.tick_ratio)
    CATime::Resolution.new(Integer(g / base_ratio(fb)), fb)
  end
  alias_method :finer, :common
  module_function :finer

  # Common resolution for a time difference (E): same group -> the common
  # grid; cross-group -> the fixed-group resolution (a :M/:Y difference only
  # arises from two calendar operands), coarsened to `(1,:D)` when the fixed
  # side is a week (a week is not calendar-alignable, but both sides convert
  # into days exactly).  :W is the only such coarsening: a fixed resolution
  # whose tick does not tile a day (e.g. "7 hours") is returned as-is, and
  # the calendar side then fails to convert into it, so the subtraction
  # raises downstream rather than being silently coarsened.
  def diff_unit(u1, u2)
    a = res(u1); b = res(u2)
    return common(a, b) if same_group?(a, b)
    fx = CALENDAR.key?(a.base) ? b : a
    fx.base == :W ? CATime::Resolution.new(1, :D) : fx
  end

  # Tick ratio from `from` to `to` (how many `to` ticks per `from` tick), or
  # nil if they are in different groups (not inter-convertible by a fixed
  # ratio).  Folds each resolution's count.
  def ratio(from, to)
    a = res(from); b = res(to)
    return nil unless same_group?(a, b)
    a.tick_ratio / b.tick_ratio
  end

  # Target ticks per source tick for the strict unit-change surface
  # (CATime#to_unit / CATimedelta#to_unit): accepted only when the source tick
  # is a whole multiple of the target tick, so every value re-expresses
  # exactly on the finer grid.  A coarser target (which would round) and a
  # cross-group pair (no fixed ratio at all) both raise -- unlike
  # convert_scale! / convert_instant!, which coarsen when the values happen to
  # allow it, this decides on the units alone.
  def multiple_factor(from, to)
    a = res(from); b = res(to)
    return 1 if a == b
    r = ratio(a, b)
    if r.nil?
      raise ArgumentError,
            "cannot express #{a} in #{b}: calendar units (:Y/:M) and " \
            "fixed-length units (:W/:D/:h/:s/...) have no fixed ratio"
    end
    unless r.denominator == 1
      raise ArgumentError,
            "cannot express #{a} in whole #{b} ticks " \
            "(a #{a} tick is not a whole multiple of a #{b} tick)"
    end
    r.numerator
  end

  # `storage * factor` with a loud overflow guard: widening a wide time range
  # into a fine unit can exceed int64, and a silent wrap would give a wrong
  # instant / duration.  Checks the extremes (they bound every element), then
  # multiplies.  Shared by every coarse->fine conversion (arithmetic,
  # comparison, search).
  #
  # min / max skip masked cells, so a masked cell does not decide the range:
  # it carries no value to convert, and whatever bits sit under the mask are
  # not a time.  They answer UNDEF when there is nothing to bound (empty, or
  # every cell masked), and then there is nothing to guard either.
  def widen(storage, factor)
    return storage if factor == 1
    lo = storage.min
    unless lo == UNDEF
      lim = 2**63 - 1
      [lo, storage.max].each do |x|
        next if (Integer(x) * factor).abs <= lim
        raise RangeError,
              "time unit conversion overflows int64: the time range is " \
              "too wide to widen into this resolution (x#{factor})"
      end
    end
    storage * factor
  end

  # SCALE conversion (durations / timedelta): convert an int64 storage CArray
  # from `from` unit to `to` unit by the fixed ratio.  coarse->fine multiplies;
  # fine->coarse divides only when every value is exact; cross-group ALWAYS
  # raises -- a :M / :Y duration has no fixed ratio to days (a month is
  # calendar-variable), so it genuinely cannot scale to seconds.
  def convert_scale!(storage, from, to)
    a = res(from); b = res(to)
    return storage if a == b
    r = ratio(a, b)
    if r.nil?
      raise ArgumentError,
            "cannot scale duration #{a} to #{b}: calendar units " \
            "(:Y/:M) and fixed-length units (:W/:D/:h/:s/...) have no fixed " \
            "ratio (a month / year is calendar-variable)"
    end
    scaled = widen(storage, r.numerator)    # coarse -> fine: lossless multiply
    return scaled if r.denominator == 1
    unless (scaled % r.denominator).eq(0).all
      raise ArgumentError,
            "cannot scale duration #{a} to #{b} without loss: " \
            "some values are not a whole multiple of #{b} " \
            "(finer resolution would be truncated)"
    end
    scaled / r.denominator
  end

  # SCALE conversion with truncation: like convert_scale! but a fine->coarse
  # conversion drops the sub-`to` remainder (truncating toward zero) instead of
  # raising.  A duration is a magnitude, so it shrinks toward zero rather than
  # flooring toward the past the way an instant does.  Used by
  # CATimedelta#to_unit and by dt +/- td, where the result keeps the time's
  # unit and a finer duration is truncated to it (a :D time + a 5 h duration
  # is + 0 days; + 30 h is + 1 day).  Cross-group still raises (a calendar
  # duration has no fixed ratio to a fixed unit).
  def convert_scale_trunc(storage, from, to)
    a = res(from); b = res(to)
    return storage if a == b
    r = ratio(a, b)
    if r.nil?
      raise ArgumentError,
            "cannot scale duration #{a} to #{b}: calendar units " \
            "(:Y/:M) and fixed-length units (:W/:D/:h/:s/...) have no fixed " \
            "ratio (a month / year is calendar-variable)"
    end
    scaled = widen(storage, r.numerator)
    r.denominator == 1 ? scaled : scaled / r.denominator   # toward zero
  end

  # INSTANT conversion (absolute datetimes): unlike a duration, a time :M
  # value HAS a well-defined instant (the month's first midnight), so a
  # cross-group cast is possible via civil-date algebra even though no fixed
  # ratio exists (a :M time casts to :s, a :M duration cannot).  Same-group
  # falls back to the ratio.
  #   - calendar (:M/:Y) -> fixed (<= :D): always exact (widen to the finer
  #     grid).  :W is rejected (month / year starts are not week-aligned).
  #   - fixed -> calendar: exact only when the instant lands on the calendar
  #     boundary (midnight of the 1st), else raises.
  def convert_instant!(storage, from, to)
    a = res(from); b = res(to)
    return storage if a == b
    return convert_scale!(storage, a, b) if ratio(a, b)   # same group
    if CALENDAR.key?(a.base)
      convert_instant_calendar_to_fixed(storage, a, b)   # widen
    else
      convert_instant_fixed_to_calendar(storage, a, b)   # coarsen (exact-or-raise)
    end
  end

  # calendar time (Resolution `from`) -> days since the epoch (int64
  # CArray).  Folds the resolution count (value = count-Y/M buckets).
  def calendar_days_since_epoch(storage, from)
    ones = CArray.int64(*storage.shape) { 1 }
    if from.base == :M
      abs = storage * from.count + 1970 * 12           # absolute month ordinal
      y   = CATimeCivil.floor_divide(abs, 12)
      m   = abs - y * 12 + 1
      CATimeCivil.days_from_civil(y, m, ones)
    else                                               # :Y
      CATimeCivil.days_from_civil(storage * from.count + 1970, ones, ones)
    end
  end

  # calendar time -> fixed-length grid: the widening half of
  # convert_instant!.  Goes through the day count, so the target grid has
  # to tile a day exactly (:W is rejected -- month starts are not
  # week-aligned).  Always exact once that holds.
  def convert_instant_calendar_to_fixed(storage, from, to)
    r = ratio(CATime::Resolution.new(1, :D), to)   # ticks of `to` per day
    unless r.denominator == 1
      raise ArgumentError,
            "cannot convert calendar time #{from} to #{to} " \
            "(a day boundary is not aligned to the #{to} grid)"
    end
    widen(calendar_days_since_epoch(storage, from), r.numerator)
  end

  # fixed-length grid -> calendar time: the coarsening half of
  # convert_instant!, exact-or-raise.  Every instant must land on a day
  # boundary and then on the calendar boundary itself (the 1st, and
  # January too for :Y), since a mid-month instant has no :M value.
  def convert_instant_fixed_to_calendar(storage, from, to)
    rd = ratio(CATime::Resolution.new(1, :D), from)  # `from` ticks per day
    days =
      if rd.denominator == 1
        n = rd.numerator
        unless (storage % n).eq(0).all
          raise ArgumentError,
                "cannot convert time #{from} to #{to} without loss " \
                "(instant is not on a day boundary)"
        end
        storage / n
      else                                             # coarser than a day (:W)
        storage * (from.tick_ratio / 86400r).to_i
      end
    y, m, d = CATimeCivil.civil_from_days(days)
    on_boundary = d.eq(1)
    on_boundary &= m.eq(1) if to.base == :Y
    unless on_boundary.all
      raise ArgumentError,
            "cannot convert time #{from} to #{to} without loss " \
            "(instant is not on a #{to} boundary)"
    end
    ord = to.base == :M ? (y * 12 + (m - 1) - 1970 * 12) : (y - 1970)
    if to.count > 1
      unless (ord % to.count).eq(0).all
        raise ArgumentError,
              "cannot convert time #{from} to #{to} without loss " \
              "(instant is not on a #{to} boundary)"
      end
      ord = CATimeCivil.floor_divide(ord, to.count)
    end
    ord
  end

  # INSTANT conversion that floors instead of raising: the storage-resolution
  # change behind CATime#to_unit.  A coarser target keeps the bucket the
  # instant falls in (floor toward the past, the direction construction and
  # `floor` already use), so no element is rejected for sitting off the
  # target grid -- a resolution change is a cast, not an assertion.  The
  # widening half is untouched and stays exact, and :Y/:M -> :W still raises
  # (a month head is not week-aligned, so widening there would move the
  # instant).
  def convert_instant_floor(storage, from, to)
    a = res(from); b = res(to)
    return storage if a == b
    r = ratio(a, b)
    if r                                                # same group
      scaled = widen(storage, r.numerator)
      r.denominator == 1 ? scaled
                         : CATimeCivil.floor_divide(scaled, r.denominator)
    elsif CALENDAR.key?(a.base)
      convert_instant_calendar_to_fixed(storage, a, b)   # widen, always exact
    else
      convert_instant_fixed_to_calendar_floor(storage, a, b)
    end
  end

  # fixed-length grid -> calendar time, flooring: the instant's own year /
  # month, whatever day and time it carries.  The flooring counterpart of
  # convert_instant_fixed_to_calendar.
  def convert_instant_fixed_to_calendar_floor(storage, from, to)
    rd   = ratio(CATime::Resolution.new(1, :D), from)   # `from` ticks per day
    days =
      if rd.denominator == 1
        CATimeCivil.floor_divide(storage, rd.numerator)
      else                                             # coarser than a day (:W)
        storage * (from.tick_ratio / 86400r).to_i
      end
    y, m, = CATimeCivil.civil_from_days(days)
    ord = to.base == :M ? (y * 12 + (m - 1) - 1970 * 12) : (y - 1970)
    to.count > 1 ? CATimeCivil.floor_divide(ord, to.count) : ord
  end
end

class CATime
  # @overload new(*shape, unit: :ns)
  #   Allocates a new int64 storage CArray of the given `shape` and
  #   wraps it as a CATime Face with the given `unit`. The
  #   reference epoch is the Unix epoch (1970-01-01 UTC).
  #   @param shape [Array<Integer>] shape of the new CATime.
  #   @param unit [Symbol] resolution unit (`:Y`, `:M`, `:W`, `:D`,
  #     `:h`, `:m`, `:s`, `:ms`, `:us`, `:ns`, ...).
  #   @return [CATime]
  def self.new(*shape, unit: :ns)
    raw = CArray.int64(*shape)
    wrap(raw, unit: unit)
  end

  # @overload wrap(raw, unit: :ns)
  #   Zero-copy Face wrap of an existing int64 CArray.  `unit` is a
  #   {Resolution} (or a Symbol / String it parses from).
  #   @param raw [CArray] int64 storage.
  #   @param unit [Resolution, Symbol, String] tick resolution.
  #   @return [CATime]
  def self.wrap(raw, unit: :ns)
    __wrap__(raw, unit)
  end

  # Element-return class: a single time element carries both its
  # int64 count and its resolution, so scalar access (ca[i,j]) round-trips
  # through this rather than a bare Integer.
  class Element
    include Comparable

    # @!visibility private
    UNIT_TO_SECONDS = {
      Y:  365.25 * 86400, M: 30.5 * 86400, W: 7 * 86400, D: 86400,
      h: 3600, m: 60, s: 1,
      ms: 1.0e-3, us: 1.0e-6, ns: 1.0e-9,
      ps: 1.0e-12, fs: 1.0e-15, as: 1.0e-18
    }.freeze

    # storage + value/unit accessors + initialize are C-implemented in
    # ext/ca_obj_datetime.c (= TypedData_Make_Struct fast path).
    # Methods below are Ruby-side; they call value/unit which are C accessors.
    #
    # Calendar breakdown is delegated to Ruby Date / Time (the scalar pays one
    # object's cost, unlike the vectorized array accessors), but exactly: a
    # :M / :Y value decodes through Date#next_month / #next_year (NOT the
    # 30.5-day UNIT_TO_SECONDS approximation, which drifts), and a fixed-unit
    # value through an exact Rational-second Time.at.  All UTC.

    EPOCH_JD = 2440588  # Julian Day Number of 1970-01-01

    # @return [Time] the instant this scalar denotes (UTC).  For a calendar
    #   unit this is the first instant (midnight of day 1) of the granule.
    def to_time
      require 'time'
      require 'date'
      case unit.base
      when :Y then d = epoch_date.next_year(value * unit.count);  Time.utc(d.year, d.month, d.day)
      when :M then d = epoch_date.next_month(value * unit.count); Time.utc(d.year, d.month, d.day)
      else
        Time.at(Rational(value) * unit.tick_ratio, in: 'UTC')  # exact seconds
      end
    end

    # @return [Date] the date this scalar denotes (UTC).  A sub-day unit is
    #   floored to its day.
    def to_date
      require 'date'
      case unit.base
      when :Y then epoch_date.next_year(value * unit.count)
      when :M then epoch_date.next_month(value * unit.count)
      when :W then Date.jd(EPOCH_JD + value * unit.count * 7, Date::GREGORIAN)
      when :D then Date.jd(EPOCH_JD + value * unit.count, Date::GREGORIAN)
      else         Date.jd(EPOCH_JD + floor_to_days_since_epoch, Date::GREGORIAN)  # sub-day: floor to day
      end
    end

    # @return [DateTime] the instant this scalar denotes (UTC).
    def to_datetime
      to_time.to_datetime
    end

    # Unit-aware string: coarse units print at their own granularity so the
    # `(value, unit)` pair stays recoverable (a :M scalar is "2024-03", not
    # "2024-03-01T00:00:00Z", which is indistinguishable from a :D).
    # @return [String]
    def to_s
      case unit.base
      when :Y      then format("%04d", to_date.year)
      when :M      then to_date.strftime("%Y-%m")
      when :W, :D  then to_date.strftime("%Y-%m-%d")
      else              to_time.iso8601(fractional_second_digits)  # :h .. :as (time shown)
      end
    end

    # @return [String] the instant plus its storage unit.
    def inspect
      tag = unit.count == 1 ? "#{value}#{unit.base}" : "#{value} @ #{unit}"
      "#<CATime::Element #{to_s} (#{tag})>"
    end

    # Three-way compare by INSTANT, reconciling a different unit (both are
    # brought to a common unit both reach exactly, via `diff_unit`), so two
    # datetimes are always ordered regardless of unit.  Returns nil for a
    # non-time operand (Time / DateTime are accepted); per the Comparable
    # contract that makes `==` false and `<` raise, so no explicit `==` is
    # defined (Comparable derives it: same instant -> equal, even cross-unit).
    def <=>(other)
      case other
      when Element
        u = CATimeUnitAlgebra.diff_unit(unit, other.unit)
        instant_in(u) <=> other.instant_in(u)
      when Time
        to_time <=> other.getutc
      when (defined?(DateTime) ? DateTime : nil)
        to_time <=> other.to_time.getutc
      end
    rescue ArgumentError
      nil
    end

    # Hash-key identity is unit-strict (mirrors Ruby: 1 == 1.0 but not
    # 1.eql?(1.0)), so a :s and a :ms scalar at the same instant compare `==`
    # yet key a Hash separately.
    def eql?(other)
      other.is_a?(Element) && other.unit == unit && other.value == value
    end

    # @return [Integer] a hash consistent with #eql? (unit-strict).
    def hash
      [value, unit].hash
    end

    # @overload +(td)
    #   Returns this instant advanced by a {CATimedelta::Element}.  The time
    #   is the anchor: the result keeps `self`'s unit and the duration is
    #   converted into it, truncated toward zero when finer (a :D time + a
    #   5 h duration is + 0 days; + 30 h is + 1 day) -- the same rule as the
    #   array {CATime#+}.  Only a duration in the SAME group (both calendar
    #   or both fixed) is accepted -- a cross-group step (a :s time + a :M
    #   duration) is calendar arithmetic; use `to_date` +
    #   `Date#next_month` / `#next_year` for that.
    #   @param td [CATimedelta::Element]
    #   @return [CATime::Element]
    #   @raise [TypeError, ArgumentError] on a non-timedelta / cross-group operand.
    def +(td)
      shifted_by_duration(td, 1)
    end

    # @overload -(other)
    #   Subtracting a {CATimedelta::Element} yields a {CATime::Element}
    #   (same rule as `+`); subtracting another {CATime::Element} yields
    #   the elapsed duration as a {CATimedelta::Element}, in the `diff_unit`
    #   of the two (same group -> finer unit; cross-group -> the fixed unit).
    #   @param other [CATimedelta::Element, CATime::Element]
    #   @return [CATime::Element, CATimedelta::Element]
    def -(other)
      case other
      when Element
        u = CATimeUnitAlgebra.diff_unit(unit, other.unit)
        CATimedelta::Element.new(instant_in(u) - other.instant_in(u), u)
      when CATimedelta::Element
        shifted_by_duration(other, -1)
      else
        raise TypeError, "CATime::Element - #{other.class} is not allowed"
      end
    end

    protected

    # This instant's storage value expressed in `to` unit (exact; raises if the
    # instant does not land on `to`'s grid).
    def instant_in(to)
      return value if to == unit
      CATimeUnitAlgebra.convert_instant!(CA_INT64([value]), unit, to)[0]
    end

    private

    # s +/- td: the time is the anchor, so the result keeps self's unit and
    # the duration is converted into it (truncated toward zero when finer; a
    # cross-group calendar duration raises).  Mirrors the array CATime +/-.
    def shifted_by_duration(td, sign)
      unless td.is_a?(CATimedelta::Element)
        raise TypeError,
              "CATime::Element #{sign > 0 ? '+' : '-'} #{td.class} is not " \
              "allowed (add / subtract a CATimedelta)"
      end
      tv = CATimeUnitAlgebra.convert_scale_trunc(CA_INT64([td.value]), td.unit, unit)[0]
      Element.new(value + sign * tv, unit)
    end

    # Base epoch as a Date.  next_month / next_year clamp end-of-month
    # (Jan 31 -> Feb 28), but the base is day 1, so no clamping ever occurs --
    # do not move the base off the first of the month without revisiting.
    def epoch_date
      require 'date'
      Date.new(1970, 1, 1, Date::GREGORIAN)  # proleptic Gregorian, matching to_time
    end

    # Days since the epoch for a fixed sub-day unit (floored toward the past).
    def floor_to_days_since_epoch
      sec = Rational(value) * unit.tick_ratio             # exact seconds
      (sec / 86400).floor
    end

    def fractional_second_digits
      case unit.base
      when :ms                then 3
      when :us                then 6
      when :ns, :ps, :fs, :as then 9  # Time caps at nanoseconds; finer is not shown
      else                         0
      end
    end
  end
end

class CATimedelta
  # @overload new(*shape, unit: :ns)
  #   Allocates a new int64 storage CArray of the given `shape` and
  #   wraps it as a CATimedelta Face with the given `unit`.
  #   @param shape [Array<Integer>] shape of the new CATimedelta.
  #   @param unit [Symbol] duration unit.
  #   @return [CATimedelta]
  def self.new(*shape, unit: :ns)
    raw = CArray.int64(*shape)
    wrap(raw, unit: unit)
  end

  # @overload wrap(raw, unit: :ns)
  #   Zero-copy Face wrap of an existing int64 CArray as a duration.
  #   @param raw [CArray] int64 storage.
  #   @param unit [CATime::Resolution, Symbol, String] tick resolution.
  #   @return [CATimedelta]
  def self.wrap(raw, unit: :ns)
    __wrap__(raw, unit)
  end

  # A single duration: an integer tick count plus the resolution those ticks
  # are counted in.  What a scalar read of a {CATimedelta} returns.
  class Element
    include Comparable
    # @!visibility private
    UNIT_TO_SECONDS = CATime::Element::UNIT_TO_SECONDS

    # storage + value/unit accessors + initialize are C-implemented in
    # ext/ca_obj_timedelta.c (= TypedData_Make_Struct fast path).
    # Methods below are Ruby-side; they call value/unit which are C accessors.

    # @return [Rational] the exact duration in seconds.  A :Y / :M duration
    #   has no exact second count (a month / year is calendar-variable), so it
    #   raises rather than silently handing back a 30.5-day approximation --
    #   use {#to_seconds_approx} when an estimate is acceptable.
    #   @raise [ArgumentError] for a :Y / :M unit.
    def to_seconds
      unless CATimeUnitAlgebra::FIXED.key?(unit.base)
        raise ArgumentError,
              "CATimedelta #{unit} has no exact seconds (a :#{unit.base} is " \
              "calendar-variable); use to_seconds_approx for an estimate"
      end
      Rational(value) * unit.tick_ratio                    # exact seconds
    end

    # @return [Float] an approximate duration in seconds, using nominal
    #   lengths (a month = 30.5 days, a year = 365.25 days).  The name makes
    #   the approximation explicit at the call site.
    def to_seconds_approx
      value * unit.count * (UNIT_TO_SECONDS[unit.base] || 1)
    end

    # @return [String] the value followed by its unit.
    def to_s
      unit.count == 1 ? "#{value}#{unit.base}" : "#{value} @ #{unit}"
    end

    # @return [String]
    def inspect
      "#<CATimedelta::Element #{to_s}>"
    end

    # Three-way compare, reconciling a different unit by the fixed ratio.  A
    # cross-group pair (a :M vs a :s duration) has no order -- there is no fixed
    # ratio -- so it returns nil (Comparable then makes `<` raise and `==`
    # false).  No explicit `==` is defined; Comparable derives it.
    def <=>(other)
      return nil unless other.is_a?(Element)
      return nil unless CATimeUnitAlgebra.same_group?(unit, other.unit)
      u = CATimeUnitAlgebra.finer(unit, other.unit)
      duration_in(u) <=> other.duration_in(u)
    rescue ArgumentError
      nil
    end

    def eql?(other)
      other.is_a?(Element) && other.unit == unit && other.value == value
    end

    # @return [Integer] a hash consistent with #eql? (unit-strict).
    def hash
      [value, unit].hash
    end

    # @overload +(other)
    #   Returns the sum of two durations, promoting to the finer unit.  A
    #   cross-group operand (a :M + a :s duration) has no fixed relation and
    #   raises.
    #   @param other [CATimedelta::Element]
    #   @return [CATimedelta::Element]
    def +(other) = combined_with_duration(other, 1)

    # @overload -(other)
    #   Returns the difference of two durations (finer unit; cross-group raises).
    #   @param other [CATimedelta::Element]
    #   @return [CATimedelta::Element]
    def -(other) = combined_with_duration(other, -1)

    # @overload *(n)
    #   Returns this duration scaled by an Integer.
    #   @param n [Integer]
    #   @return [CATimedelta::Element]
    def *(n)
      raise TypeError, "CATimedelta::Element * #{n.class} is not allowed (Integer only)" unless n.is_a?(Integer)
      Element.new(value * n, unit)
    end

    # @overload /(other)
    #   By an Integer -> a scaled {CATimedelta::Element}, the quotient
    #   truncated toward zero (a duration is a magnitude, so it shrinks
    #   toward zero -- the same direction {CATimedelta#/} and #to_unit
    #   take, not Ruby Integer division's floor); by another
    #   {CATimedelta::Element} -> their dimensionless ratio as a `Rational`
    #   (both brought to the finer unit; cross-group raises).
    #   @param other [Integer, CATimedelta::Element]
    #   @return [CATimedelta::Element, Rational]
    def /(other)
      case other
      when Integer then Element.new(Rational(value, other).truncate, unit)
      when Element
        u = CATimeUnitAlgebra.finer(unit, other.unit)
        Rational(duration_in(u), other.duration_in(u))
      else
        raise TypeError, "CATimedelta::Element / #{other.class} is not allowed"
      end
    end

    protected

    # This duration's value expressed in `to` unit (exact scale; raises on a
    # cross-group or non-whole conversion).
    def duration_in(to)
      return value if to == unit
      CATimeUnitAlgebra.convert_scale!(CA_INT64([value]), unit, to)[0]
    end

    private

    def combined_with_duration(other, sign)
      unless other.is_a?(Element)
        raise TypeError,
              "CATimedelta::Element #{sign > 0 ? '+' : '-'} #{other.class} is not allowed"
      end
      u = CATimeUnitAlgebra.finer(unit, other.unit)
      Element.new(duration_in(u) + sign * other.duration_in(u), u)
    end
  end
end

# ============================================================================
# Ruby surface operators (CATime)
# ============================================================================

class CATime
  # NOTE: for internal ops accessing the storage CArray (= int64), use `parent`
  # directly. `value` is a user-facing canonical method (= mask-strip CARefer
  # view) with a lift hook deployed in the C layer; do not shadow.

  # Sanctioned external accessor that pairs with the existing `unit` reader.
  # An interop bridge (carray-xarray, carray-pycall consumers, etc.) can
  # read out the int64 count + unit without reaching into `parent` (= an
  # internal-contract accessor).  The reference epoch is the implicit Unix
  # epoch (1970-01-01 UTC) baked into the convention at the top of this
  # file and into the C layer's Time.at-based decoding; it is not a
  # per-instance state and therefore is not exposed as an accessor.
  #
  #   ca.ticks               # => CArray (int64), tick counts since 1970-01-01 UTC
  #   ca.unit                # => Symbol (:Y :M :W :D :h :m :s :ms :us :ns ...)
  # @overload ticks
  #   Returns the underlying int64 CArray of tick counts since the
  #   Unix epoch (1970-01-01 UTC) — the k-th tick of this array's
  #   resolution (see §4 of docs/CATime.md).
  #   @return [CArray]
  def ticks
    parent
  end

  # @overload to_unit(unit)
  #   Returns the same instants re-expressed on the `unit` grid: a new
  #   {CATime} whose storage resolution is `unit`.  Changing the resolution
  #   is a cast, not an assertion -- the same relation `CArray.time` has to
  #   its input:
  #
  #   - **Finer target** (`:D` -> `:h`, `:Y` -> `:M`, `:M` -> `:s`): exact.
  #     Every instant lands on the new grid unchanged.
  #   - **Coarser target** (`:h` -> `:D`, `:D` -> `:M`): each instant floors
  #     to the head of the `unit` tick it falls in -- toward the past, so a
  #     pre-epoch instant floors the same way a post-epoch one does.  Use
  #     {#ceil} / {#round} first to land on a different boundary.
  #
  #   The calendar / fixed-length boundary is crossed by civil-date algebra,
  #   not by a ratio: a `:M` value is a real instant (the month's first
  #   midnight), so `:M` -> `:D` widens exactly and `:D` -> `:M` floors to
  #   the containing month.  `:Y` / `:M` -> `:W` is the one refusal, since a
  #   month head is not week-aligned and widening would move the instant.
  #
  #   A *duration* has no such conversion ({CATimedelta#to_unit} truncates
  #   toward zero and refuses to cross the boundary at all).
  #   @param unit [Resolution, Symbol, String] target resolution.
  #   @return [CATime]
  #   @raise [ArgumentError] on `:Y` / `:M` -> `:W`.
  #   @raise [RangeError] when the widened ticks overflow int64.
  def to_unit(unit)
    to = CATime::Resolution.parse(unit)
    CATimeUnitAlgebra.convert_instant_floor(parent, self.unit, to).time(unit: to)
  end

  # @overload +(other)
  #   Returns `self + other` for a {CATimedelta}: the time is the
  #   anchor, so the result keeps `self`'s unit and the duration is converted
  #   into it (a duration finer than `self`'s unit is truncated to it; a
  #   cross-group calendar duration raises).  Adding two datetimes is
  #   ill-defined.
  #   @param other [CATimedelta]
  #   @return [CATime]
  #   @raise [TypeError] on a non-timedelta operand.
  def +(other)
    case other
    when CATimedelta
      (parent + CATimeUnitAlgebra.convert_scale_trunc(other.parent, other.unit, unit)).time(unit: unit)
    when CATime
      raise TypeError, "CATime + CATime is ill-defined"
    else
      raise TypeError, "CATime + #{other.class} is not allowed (use CATimedelta)"
    end
  end

  # @overload -(other)
  #   Subtracting a {CATimedelta} yields a {CATime} at `self`'s unit (the
  #   duration is converted into it, truncated when finer); subtracting
  #   another {CATime} yields a {CATimedelta} at the finer of the two
  #   units (cross-group falls to the fixed unit).
  #   @param other [CATimedelta, CATime]
  #   @return [CATime, CATimedelta]
  #   @raise [TypeError] on an unsupported operand.
  def -(other)
    case other
    when CATimedelta
      (parent - CATimeUnitAlgebra.convert_scale_trunc(other.parent, other.unit, unit)).time(unit: unit)
    when CATime
      u = CATimeUnitAlgebra.diff_unit(unit, other.unit)
      a = CATimeUnitAlgebra.convert_instant!(parent, unit, u)
      b = CATimeUnitAlgebra.convert_instant!(other.parent, other.unit, u)
      (a - b).timedelta(unit: u)
    else
      raise TypeError, "CATime - #{other.class} is not allowed"
    end
  end

  # Element-wise comparison (< <= > >= <=>) rides the core comparison Face
  # gate (ca_face_reconcile_comparison in ext/ca_obj_face.c): the inherited
  # CArray operators descend to storage and reconcile a CATime RHS in a
  # different unit via to_comparable, returning a boolean CArray.  <=> is the
  # base CArray#<=> composed from the (gated) > and <.

  # Element decode convention via the C-layer macro
  # `CA_FACE_STORAGE_TO_SCALAR_IF_FACE`: no Ruby `[]` override is needed, a
  # scalar auto-decodes on all scalar-return paths such as `ca[i,j,k]` /
  # `ca[k]`.  storage_to_scalar itself lives in C (ext/ca_obj_datetime.c)
  # so the hot path stays off Ruby method dispatch.  Its write counterpart
  # is scalar_to_storage (below, surface -> storage on store).

  # @!group Reductions

  # min / max are order-structure reductions: they ride the core reduce
  # Face gate (ORDERABLE storage descent + output re-lift, see
  # ext/mkkernel.rb face_gate: :relift), so no Ruby override is needed --
  # the inherited CArray#min / #max handle the Element / CATime return
  # shapes directly.  minmax is the paired form; it has no core gate, so
  # re-lift both extremes here.  They are actual elements, so they keep the
  # storage unit (no rounding, unlike mean).

  # @overload minmax(*axes, **opts)
  #   Returns the earliest and latest time as a `[min, max]` pair (§8).
  #   @return [Array(Element, Element), Array(CATime, CATime)]
  def minmax(*args, **opts)
    lo, hi = parent.minmax(*args, **opts)
    [relift_extremum(lo), relift_extremum(hi)]
  end

  def relift_extremum(r)
    case r
    when Integer then Element.new(r, unit)
    when CArray  then r.time(unit: unit)
    else r
    end
  end
  private :relift_extremum

  # The centroid / spread / order reductions report on the array's own grid:
  # they run on the storage ticks and round the result back to the nearest
  # tick of `unit`.  A caller who needs a finer answer declares the grid
  # first (`t.to_unit(:ms).mean`) -- the same rule linear_fetch follows.
  # Rounding is to nearest, not toward zero: a truncating round would flip
  # the direction of the error at the epoch.

  # @overload mean(axis: nil, **opts)
  #   Returns the centroid time on `self`'s unit (§8), rounded to the
  #   nearest tick.
  #   @return [Element, CATime]
  def mean(*args, **opts)
    reduce_on_own_grid(:mean, :time, args, opts)
  end

  # @overload median(axis: nil, **opts)
  #   Returns the median time on `self`'s unit (§8).  An odd-count full
  #   reduction is an actual element (exact); the even-count / per-axis
  #   cases interpolate and round to the nearest tick.
  #   @return [Element, CATime]
  def median(*args, **opts)
    reduce_on_own_grid(:median, :time, args, opts)
  end

  # @overload percentile(*p, axis: nil, **opts)
  #   Returns the percentile instants on `self`'s unit, in the shapes the
  #   plain {CArray#percentile} uses: one `p` reduces to a single value
  #   (an {Element}, or a {CATime} with `axis:`), two or more `p` give an
  #   Array of those.
  #   @return [Element, CATime, Array<Element>, Array<CATime>]
  def percentile(*args, **opts)
    reduce_on_own_grid(:percentile, :time, args, opts)
  end

  # @overload quantile(axis: nil, **opts)
  #   Returns the five quartile instants `[p0, p25, p50, p75, p100]` on
  #   `self`'s unit (shorthand for `percentile(0, 25, 50, 75, 100)`).
  #   @return [Array<Element>, Array<CATime>]
  def quantile(*args, **opts)
    reduce_on_own_grid(:quantile, :time, args, opts)
  end

  # @overload stddev(axis: nil, **opts)
  #   Returns the spread of the instants as a {CATimedelta} (a duration) on
  #   `self`'s unit.  A spread is not a lattice point, so the rounding costs
  #   more here than for a centroid: on a coarse unit use
  #   `t.to_unit(:h).stddev` when the precision matters (§8).
  #   @return [CATimedelta::Element, CATimedelta]
  def stddev(*args, **opts)
    reduce_on_own_grid(:stddev, :timedelta, args, opts)
  end

  # @overload stddevp(axis: nil, **opts)
  #   Returns the population spread as a {CATimedelta}, in the same shapes
  #   as {#stddev}.
  #   @return [CATimedelta::Element, CATimedelta]
  def stddevp(*args, **opts)
    reduce_on_own_grid(:stddevp, :timedelta, args, opts)
  end

  # @overload sum(*)
  #   Not supported; use {#mean} for a centroid.
  #   @raise [TypeError] always.
  def sum(*)
    raise TypeError, "CATime#sum is ill-defined; use mean for centroid"
  end

  # @overload variance(*)
  #   Not supported: the variance of instants has squared-time units, which
  #   no type represents (ill-defined, like {#sum}).  Use {#stddev} for the
  #   spread as a duration.
  #   @raise [TypeError] always.
  def variance(*); raise TypeError, "CATime#variance is ill-defined (squared-time units); use stddev"; end

  # @overload variancep(*)
  #   Not supported, for the same reason as {#variance}.  Use {#stddevp}.
  #   @raise [TypeError] always.
  def variancep(*); raise TypeError, "CATime#variancep is ill-defined (squared-time units); use stddevp"; end
  # @!endgroup

  # sort / partition ride the core sort Face gate (ORDERABLE storage
  # descent + output re-lift): the inherited CArray#sort / #partition
  # return a sorted CATime with the same unit, so no override is
  # needed.

  # @overload to_comparable(operand)
  #   Brings `operand` into `self`'s unit space for a direct storage
  #   comparison (comparison operators / search family / linear_section).
  #   `self` is the reference Face -- always one of our classes -- so it
  #   class-dispatches the operand rather than requiring every operand type
  #   to know every Face (which a core class like Time could not).
  #   CATime is ORDERABLE but not COMPARABLE (an operand may carry a
  #   different unit or shape), so the gate routes the operand through here.
  #
  #   Accepted operands: another {CATime} (unit-rescaled to self),
  #   a {Element} (lifted to a length-1 CATime), a Ruby `Time`, and a
  #   Ruby `DateTime` (both absolute instants converted to self's unit,
  #   Unix epoch, UTC).  A `String` is out of scope (parsing is a separate,
  #   opposite-direction mechanism).  A bare Integer / other type raises;
  #   descend to `ca.parent` to compare the hidden storage directly.
  #
  #   The rescale is an INSTANT conversion (convert_instant!), lossless: a
  #   coarser->finer unit always converts; a finer->coarser unit converts only
  #   when every value lands exactly on the coarser grid, else raises.  Unlike
  #   a duration, a cross-group time cast IS possible via civil-date
  #   algebra (a :M value has a well-defined instant): :M/:Y widen exactly to
  #   :D and finer, and a fixed operand coarsens to :M/:Y only when it sits on
  #   the calendar boundary (:W is the one exception -- month/year starts are
  #   not week-aligned, so :Y/:M <-> :W raises).
  #   @param operand [CATime, CATime::Element, Time, DateTime]
  #   @return [CATime] in self's unit.
  #   @raise [TypeError, ArgumentError] on an unreconcilable operand / unit.
  def to_comparable (operand)
    case operand
    when CATime
      return operand if operand.unit == unit
      CATimeUnitAlgebra.convert_instant!(operand.parent, operand.unit, unit)
                           .time(unit: unit)
    when CATime::Element
      lifted = CATime.wrap(CA_INT64([operand.value]), unit: operand.unit)
      to_comparable(lifted)
    when Time
      # Reuse the single-literal builder; it yields a length-1 CATime
      # in the requested (= self's) resolution.
      CArray.time(operand, unit: unit)
    when defined?(DateTime) && DateTime
      to_comparable(operand.to_time.utc)
    else
      raise TypeError,
            "CATime cannot reconcile #{operand.class} " \
            "(use ca.parent to compare the raw int64 storage directly)"
    end
  end

  # @overload scalar_to_storage(surface)
  #   Write-direction counterpart of storage_to_scalar (the store hook fired
  #   from rb_ca_obj2ptr): brings a surface value object into this Face's
  #   int64 storage (count in self's unit since the Unix epoch) so a scalar
  #   store round-trips with a fetch.  A {Element} / `Time` / `DateTime` is
  #   reconciled to self's unit via {#to_comparable} (same lossless
  #   discipline: a cross-group unit or a non-exact finer->coarser cast
  #   raises).  A bare Integer (the documented `.parent` raw-storage escape)
  #   and a String (parsing is a separate, opposite-direction mechanism)
  #   pass through unchanged to the storage cast.
  #   @param surface [Element, Time, DateTime, Integer, String]
  #   @return [Integer, Object] the storage-domain value, or `surface`
  #     unchanged for a pass-through type.
  #   @raise [TypeError, ArgumentError] on an unreconcilable surface / unit.
  def scalar_to_storage (surface)
    case surface
    when Integer, String
      surface
    else
      to_comparable(surface).parent[0]
    end
  end

  # NOTE: search (bsearch / search / bsearch_addr) and linear_section need NO
  # per-method override.  The C kernel gate descends an ORDERABLE Face
  # reference to storage and, for a Face query, calls to_comparable itself to
  # reconcile it -- so declaring ORDERABLE (init flag) and defining
  # to_comparable (above) is the whole contract.  linear_fetch is the one
  # exception: it returns a value rather than a position, so it re-lifts
  # (below).

  # @overload linear_fetch(addr, axis: nil)
  #   Returns the time at the fractional position `addr` on this array's
  #   grid, interpolating between the two bracketing instants.  The inverse
  #   of `linear_section`, and the reason for the override: `linear_fetch`
  #   returns a *value*, so the result is a {CATime} again, whereas
  #   `linear_section` returns a position and stays a plain index.
  #
  #   The result keeps `self`'s unit -- the array's grid is the output grid,
  #   so an instant that lands between two ticks is rounded to the nearest
  #   one.  Widen the grid first when the interpolation needs finer
  #   resolution: `t.to_unit(:ms).linear_fetch(addr)` interpolates on the
  #   millisecond grid.  (Unlike {#mean} / {#median}, which collapse the axis
  #   and therefore have no output grid to preserve, so they refine the
  #   resolution instead.)
  #
  #   An out-of-range `addr` yields UNDEF rather than the NaN that a plain
  #   float axis returns -- int64 storage has no NaN to carry a sentinel.  A
  #   masked `addr` cell stays UNDEF (the kernel's own rule: an undetermined
  #   query gets an undetermined answer).
  #   @param addr [Float, CArray] fractional position(s) into `self`.
  #   @param axis [Integer, nil]
  #   @return [Element, CATime] an {Element} for a scalar `addr`, `nil` when
  #     that single answer is undetermined.
  def linear_fetch (addr, **opts)
    r = parent.float64.linear_fetch(addr, **opts)
    case r
    when CArray
      # mask_invalid before the int64 cast: the cast turns a NaN into 0, which
      # would read as the epoch instead of "no answer".
      r.mask_invalid.round.int64.time(unit: unit)
    when Numeric
      # Scalar query.  Out of range -> nil, joining the nil the kernel already
      # returns for a masked scalar query: one "no answer" on this path.
      r.to_f.nan? ? nil : Element.new(r.round, unit)
    else
      r                                   # nil (masked scalar query)
    end
  end

  # ====================================================================
  # pandas .dt.* style field accessors
  # ====================================================================
  #
  # Face-strip semantic: each accessor returns a CArray of Integer / bool
  # (= year / month / etc. are not time, they descend to the storage
  # type), computed directly from the storage int64.
  # ====================================================================

  # @overload to_time
  #   Converts every element to a Ruby `Time` (UTC), returned as an object
  #   CArray.  Array-level counterpart to {Element#to_time}.
  #   @return [CArray]
  def to_time
    require 'time'
    if CATimeUnitAlgebra::FIXED.key?(unit.base)
      f = unit.tick_ratio                        # exact seconds / tick (Rational)
      parent.convert(:object) {|v| Time.at(v * f, in: 'UTC')}
    else                                         # calendar: exact granule midnight
      (days_since_epoch * 86400).convert(:object) {|v| Time.at(v, in: 'UTC')}
    end
  end

  # @overload to_date
  #   Converts every element to a Ruby `Date` (UTC), returned as an object
  #   CArray.  A sub-day unit floors to its day.  Array-level counterpart to
  #   {Element#to_date}.
  #   @return [CArray]
  def to_date
    require 'date'
    # 2440588 = JD of 1970-01-01; proleptic Gregorian to match to_time and the field accessors.
    days_since_epoch.convert(:object) {|d| Date.jd(2440588 + d, Date::GREGORIAN)}
  end

  # @overload to_datetime
  #   Converts every element to a Ruby `DateTime` (UTC offset 0), returned
  #   as an object CArray.
  #   @return [CArray]
  def to_datetime
    require 'date'
    to_time.convert(:object) {|t| t.to_datetime}
  end

  # @!group Field accessors
  # Each accessor returns an integer CArray with the requested calendar /
  # clock field extracted from every element (UTC), computed by vectorized
  # civil-date algebra directly on the int64 storage -- no per-cell Time.
  # Exact for every unit, including :M / :Y (where the old Time.at path drifted
  # by using 30.5-day / 365.25-day approximations).  Fields finer than the
  # storage unit collapse to their zero point, and the input mask propagates.
  # @return [CArray]
  def year
    case unit.base
    when :Y then parent * unit.count + 1970
    when :M then CATimeCivil.floor_divide(parent * unit.count + 1970 * 12, 12)
    else CATimeCivil.civil_from_days(days_since_epoch)[0]
    end
  end

  # Calendar month, 1..12.  Every cell is 1 for `:Y` storage, which does not
  # resolve months.
  # @return [CArray] integer.
  def month
    case unit.base
    when :Y then parent * 0 + 1
    when :M
      mo = parent * unit.count + 1970 * 12
      mo - CATimeCivil.floor_divide(mo, 12) * 12 + 1
    else CATimeCivil.civil_from_days(days_since_epoch)[1]
    end
  end

  # Day of the month, 1..31.  Every cell is 1 for `:Y` / `:M` storage, which
  # does not resolve days.
  # @return [CArray] integer.
  def day
    case unit.base
    when :Y, :M then parent * 0 + 1
    else CATimeCivil.civil_from_days(days_since_epoch)[2]
    end
  end

  # Hour of the day, 0..23; 0 when the storage unit is coarser than an hour.
  # @return [CArray] integer.
  def hour;   clock_field(:h); end
  # Minute of the hour, 0..59; 0 when the storage unit is coarser than a minute.
  # @return [CArray] integer.
  def minute; clock_field(:m); end
  # Second of the minute, 0..59; 0 when the storage unit is coarser than a second.
  # @return [CArray] integer.
  def second; clock_field(:s); end

  # Day of the week, Sunday = 0 .. Saturday = 6.
  # @return [CArray] integer.
  def weekday
    # 1970-01-01 is a Thursday (wday 4); Sun=0..Sat=6.
    n = days_since_epoch + 4
    n - CATimeCivil.floor_divide(n, 7) * 7          # floor-mod 7
  end

  # Day of the year, 1..366.
  # @return [CArray] integer.
  def yday
    d    = days_since_epoch
    y    = CATimeCivil.civil_from_days(d)[0]
    ones = CArray.int64(*shape) { 1 }
    d - CATimeCivil.days_from_civil(y, ones, ones) + 1
  end
  # @!endgroup

  # @overload jd
  #   Returns the Julian Day Number for each element.
  #   @return [CArray]
  def jd
    require 'date'
    to_time.convert(:int) {|t| t.to_date.jd}
  end

  # @overload ajd
  #   Returns the Astronomical Julian Day (float, offset by half a
  #   day) for each element.
  #   @return [CArray]
  def ajd
    require 'date'
    to_time.convert(:double) {|t| t.to_datetime.ajd.to_f}
  end

  # @overload is_leap
  #   Returns a boolean CArray flagging elements that fall in a
  #   leap year (UTC).
  #   @return [CArray]
  def is_leap
    y = year
    ((y % 4).eq(0) & (y % 100).ne(0)) | (y % 400).eq(0)
  end

  # @overload strftime(fmt)
  #   Returns a {CAString} whose elements are the per-cell
  #   `Time#strftime(fmt)` result (UTC).  The input mask propagates.
  #   @param fmt [String] strftime format string.
  #   @return [CAString]
  def strftime(fmt)
    CAString.wrap(to_time.convert(:object) {|t| t.strftime(fmt)})
  end

  private

  # Reduce to `kind` (:time -> CATime, :timedelta -> CATimedelta) on the
  # array's own grid.  The reduction runs on the storage ticks -- for a
  # calendar unit that means the month / year ordinal, so a :M centroid is
  # the centroid of month numbers (a caller wanting the day-space answer
  # writes to_unit(:D) first) -- and the result is rounded back to a tick.
  def reduce_on_own_grid(op, kind, args, opts)
    round_and_relift(parent.public_send(op, *args, **opts), kind)
  end

  # Round-to-nearest onto the storage grid, then wear the Face again.  An
  # Array arrives from the multi-p percentile / quantile shapes; UNDEF and
  # nil (empty or all-masked) pass through untouched.
  def round_and_relift(r, kind)
    case r
    when Numeric
      v = r.round
      kind == :timedelta ? CATimedelta::Element.new(v, unit) : Element.new(v, unit)
    when CArray
      # A cell with no answer arrives masked and the mask survives the cast.
      # NaN does not: it has no int64 image, so a `fill_value: Float::NAN`
      # cell would cast to garbage bits.  mask_invalid turns it into UNDEF,
      # which is what "no answer" means here.
      iv = r.round.mask_invalid.int64
      kind == :timedelta ? iv.timedelta(unit: unit) : iv.time(unit: unit)
    when Array
      r.map {|x| round_and_relift(x, kind)}
    else
      r    # UNDEF / nil passthrough (empty or all-masked reduction)
    end
  end

end

# ============================================================================
# Ruby surface operators (CATimedelta)
# ============================================================================

class CATimedelta
  # NOTE: internal ops use `parent` directly. `value` is a C-layer canonical
  # method (mask-strip) with a lift hook deployed in the C layer; do not
  # shadow.

  # @overload ticks
  #   Returns the underlying int64 CArray of tick counts — the duration
  #   measured in this array's resolution (see {CATime#ticks}).
  #   @return [CArray]
  def ticks
    parent
  end

  # @overload to_unit(unit)
  #   Returns the same durations re-expressed on the `unit` grid: a new
  #   {CATimedelta} whose storage resolution is `unit`.  A finer target is
  #   exact (`:D` -> `:h`); a coarser one drops the sub-`unit` remainder
  #   **toward zero** (`+30 h` -> `+1 D`, `-30 h` -> `-1 D`), the same
  #   truncation `dt + td` already applies.
  #
  #   The direction differs from {CATime#to_unit} on purpose: a time is a
  #   point on an axis, so it floors toward the past; a duration is a
  #   magnitude, so it shrinks toward zero.
  #
  #   A calendar / fixed-length pair always raises -- unlike an instant, a
  #   duration of one month has no length in days.
  #   @param unit [Resolution, Symbol, String] target resolution.
  #   @return [CATimedelta]
  #   @raise [ArgumentError] on a calendar / fixed-length pair.
  #   @raise [RangeError] when the widened ticks overflow int64.
  def to_unit(unit)
    to = CATime::Resolution.parse(unit)
    CATimeUnitAlgebra.convert_scale_trunc(parent, self.unit, to).timedelta(unit: to)
  end

  # @overload +(other)
  #   Returns `self + other`. A {CATimedelta} operand yields a
  #   {CATimedelta}; a {CATime} operand delegates to
  #   {CATime#+} (commutative).
  #   @param other [CATimedelta, CATime]
  #   @return [CATimedelta, CATime]
  #   @raise [TypeError] on incompatible operands.
  def +(other)
    case other
    when CATimedelta
      u = common_duration_unit(other.unit)
      a = CATimeUnitAlgebra.convert_scale!(parent, unit, u)
      b = CATimeUnitAlgebra.convert_scale!(other.parent, other.unit, u)
      (a + b).timedelta(unit: u)
    when CATime
      other + self  # commutative -> time's unit
    else
      raise TypeError, "CATimedelta + #{other.class} is not allowed"
    end
  end

  # @overload -(other)
  #   Returns the difference of two {CATimedelta} at the finer of the two
  #   units (a cross-group pair raises).
  #   @param other [CATimedelta]
  #   @return [CATimedelta]
  #   @raise [TypeError] on a non-timedelta operand.
  def -(other)
    case other
    when CATimedelta
      u = common_duration_unit(other.unit)
      a = CATimeUnitAlgebra.convert_scale!(parent, unit, u)
      b = CATimeUnitAlgebra.convert_scale!(other.parent, other.unit, u)
      (a - b).timedelta(unit: u)
    else
      raise TypeError, "CATimedelta - #{other.class} is not allowed"
    end
  end

  # @overload abs
  #   Returns the magnitude of each duration as a {CATimedelta} on the same
  #   unit.
  #   @return [CATimedelta]
  def abs
    parent.abs.timedelta(unit: unit)
  end

  # @overload -@
  #   Returns each duration with its sign reversed, on the same unit.
  #   @return [CATimedelta]
  def -@
    (-parent).timedelta(unit: unit)
  end

  # @overload *(other)
  #   Returns `self` scaled by an Integer.
  #   @param other [Integer]
  #   @return [CATimedelta]
  #   @raise [TypeError] when `other` is not an Integer.
  def *(other)
    case other
    when Integer then (parent * other).timedelta(unit: unit)
    else raise TypeError, "CATimedelta * #{other.class} is not allowed (Integer only)"
    end
  end

  # @overload /(other)
  #   Returns element-wise division: by Integer yields a
  #   {CATimedelta}, by another {CATimedelta} with matching `unit`
  #   yields a dimensionless CArray.
  #   @param other [Integer, CATimedelta]
  #   @return [CATimedelta, CArray]
  #   @raise [TypeError] on incompatible operands.
  def /(other)
    case other
    when Integer then (parent / other).timedelta(unit: unit)
    when CATimedelta
      u = common_duration_unit(other.unit)
      CATimeUnitAlgebra.convert_scale!(parent, unit, u) /
        CATimeUnitAlgebra.convert_scale!(other.parent, other.unit, u)
    else raise TypeError, "CATimedelta / #{other.class} is not allowed"
    end
  end

  # Element-wise comparison (< <= > >= <=>) rides the core comparison Face
  # gate (ca_face_reconcile_comparison): the inherited CArray operators
  # descend to storage and reconcile a CATimedelta RHS in a different unit
  # via to_comparable, returning a boolean CArray.

  # @!group Reductions

  # @overload sum(*args, **opts)
  #   Returns the sum of durations as a {Element} for full reduction
  #   or as a {CATimedelta} view for per-axis reduction.
  #   @return [Element, CATimedelta]
  def sum(*args, **opts)
    round_and_relift(parent.sum(*args, **opts))
  end

  # @overload mean(axis: nil, **opts)
  #   Returns the mean duration rounded to the nearest unit count.
  #   @return [Element, CATimedelta]
  def mean(*args, **opts)
    round_and_relift(parent.mean(*args, **opts))
  end

  # median / percentile / quantile / stddev / stddevp report on this array's
  # own unit, rounded to the nearest tick -- the same rule {CATime} follows.
  # A caller who needs a finer answer declares the grid first
  # (`td.to_unit(:ms).stddev`).

  # @overload median(axis: nil, **opts)
  #   Returns the median duration on `self`'s unit.
  #   @return [Element, CATimedelta]
  def median(*args, **opts)
    round_and_relift(parent.median(*args, **opts))
  end

  # @overload percentile(*p, axis: nil, **opts)
  #   Returns the percentile durations on `self`'s unit, in the shapes the
  #   plain {CArray#percentile} uses (one `p` reduces to a single value,
  #   two or more give an Array).
  #   @return [Element, CATimedelta, Array<Element>, Array<CATimedelta>]
  def percentile(*args, **opts)
    round_and_relift(parent.percentile(*args, **opts))
  end

  # @overload quantile(axis: nil, **opts)
  #   Returns the five quartile durations `[p0, p25, p50, p75, p100]` on
  #   `self`'s unit.
  #   @return [Array<Element>, Array<CATimedelta>]
  def quantile(*args, **opts)
    round_and_relift(parent.quantile(*args, **opts))
  end

  # @overload stddev(axis: nil, **opts)
  #   Returns the spread of the durations on `self`'s unit.  A spread is not
  #   a lattice point, so on a coarse unit use `td.to_unit(:h).stddev` when
  #   the precision matters.
  #   @return [Element, CATimedelta]
  def stddev(*args, **opts)
    round_and_relift(parent.stddev(*args, **opts))
  end

  # @overload stddevp(axis: nil, **opts)
  #   Returns the population spread on `self`'s unit, in the same shapes as
  #   {#stddev}.
  #   @return [Element, CATimedelta]
  def stddevp(*args, **opts)
    round_and_relift(parent.stddevp(*args, **opts))
  end

  def round_and_relift(r)
    case r
    when Numeric then Element.new(r.round, unit)
    when CArray  then r.round.mask_invalid.int64.timedelta(unit: unit)
    when Array   then r.map {|x| round_and_relift(x)}
    else r
    end
  end
  private :round_and_relift

  # @overload variance(*)
  #   Not supported: the variance of durations has squared-time units, which
  #   no type represents -- the same reason {CATime#variance} refuses.  Use
  #   {#stddev} for the spread as a duration.
  #   @raise [TypeError] always.
  def variance(*)
    raise TypeError, "CATimedelta#variance is ill-defined (squared-time units); use stddev"
  end

  # @overload variancep(*)
  #   Not supported, for the same reason as {#variance}.  Use {#stddevp}.
  #   @raise [TypeError] always.
  def variancep(*)
    raise TypeError, "CATimedelta#variancep is ill-defined (squared-time units); use stddevp"
  end

  # min / max ride the core reduce Face gate (ORDERABLE storage descent +
  # output re-lift, see ext/mkkernel.rb face_gate: :relift); the inherited
  # CArray#min / #max return the Element / CATimedelta shapes directly.
  # minmax has no core gate, so re-lift both extremes here.

  # @overload minmax(*axes, **opts)
  #   Returns the shortest and longest duration as a `[min, max]` pair.
  #   @return [Array(Element, Element), Array(CATimedelta, CATimedelta)]
  def minmax(*args, **opts)
    lo, hi = parent.minmax(*args, **opts)
    [relift_extremum(lo), relift_extremum(hi)]
  end

  def relift_extremum(r)
    case r
    when Integer then Element.new(r, unit)
    when CArray  then r.timedelta(unit: unit)
    else r
    end
  end
  private :relift_extremum
  # @!endgroup

  # sort / partition ride the core sort Face gate (ORDERABLE storage
  # descent + output re-lift); the inherited CArray#sort / #partition
  # return a sorted CATimedelta with the same unit.

  # @overload to_comparable(operand)
  #   Brings `operand` into `self`'s unit space for a direct storage
  #   comparison (see {CATime#to_comparable} for the reference-side
  #   contract).  `self` is the reference Face and class-dispatches the
  #   operand.  Coverage is deliberately narrower than CATime: only
  #   another {CATimedelta} (unit-rescaled to self) and a {Element} (lifted
  #   to a length-1 CATimedelta) are accepted.  `Time` / `DateTime` are
  #   absolute instants, not durations, so they raise -- a Face owns its own
  #   coverage.  Auto-casts to self's unit when lossless (coarser->finer
  #   always; finer->coarser only when every value is exact), otherwise
  #   raises.
  #   @param operand [CATimedelta, CATimedelta::Element]
  #   @return [CATimedelta] in self's unit.
  #   @raise [TypeError, ArgumentError] on an unreconcilable operand / unit.
  def to_comparable (operand)
    case operand
    when CATimedelta
      return operand if operand.unit == unit
      CATimeUnitAlgebra.convert_scale!(operand.parent, operand.unit, unit)
                           .timedelta(unit: unit)
    when CATimedelta::Element
      lifted = CATimedelta.wrap(CA_INT64([operand.value]), unit: operand.unit)
      to_comparable(lifted)
    else
      raise TypeError,
            "CATimedelta cannot reconcile #{operand.class} " \
            "(use ca.parent to compare the raw int64 storage directly)"
    end
  end

  # @overload scalar_to_storage(surface)
  #   Write-direction counterpart of storage_to_scalar: brings a surface
  #   value object into this Face's int64 storage (count in self's unit) so a
  #   scalar store round-trips with a fetch.  A {Element} is reconciled to
  #   self's unit via {#to_comparable} (lossless discipline; a `Time` /
  #   `DateTime` is an absolute instant, not a duration, so it raises there).
  #   A bare Integer (the `.parent` raw-storage escape) and a String pass
  #   through unchanged.
  #   @param surface [Element, Integer, String]
  #   @return [Integer, Object] the storage-domain value, or `surface`
  #     unchanged for a pass-through type.
  #   @raise [TypeError, ArgumentError] on an unreconcilable surface / unit.
  def scalar_to_storage (surface)
    case surface
    when Integer, String
      surface
    else
      to_comparable(surface).parent[0]
    end
  end

  # Search / linear_section need no per-method override: the C kernel gate
  # descends an ORDERABLE Face reference and reconciles a Face query via
  # to_comparable.  See {CATime}.

  # @overload linear_fetch(addr, axis: nil)
  #   Returns the duration at the fractional position `addr` on this array's
  #   grid, interpolating between the two bracketing durations.  Keeps
  #   `self`'s unit and rounds to it (widen the grid with {#to_unit} first
  #   when the interpolation needs finer resolution), which matches {#mean} /
  #   {#sum} -- a duration reduction stays on the grid too.  An out-of-range
  #   `addr` yields UNDEF; see {CATime#linear_fetch} for the full contract.
  #   @param addr [Float, CArray] fractional position(s) into `self`.
  #   @param axis [Integer, nil]
  #   @return [Element, CATimedelta] an {Element} for a scalar `addr`, `nil`
  #     when that single answer is undetermined.
  def linear_fetch (addr, **opts)
    r = parent.float64.linear_fetch(addr, **opts)
    case r
    when CArray  then r.mask_invalid.round.int64.timedelta(unit: unit)
    when Numeric then r.to_f.nan? ? nil : Element.new(r.round, unit)
    else r
    end
  end

  private

  # The finer of `self`'s unit and `ou` for a duration + duration / ratio.  A
  # cross-group pair (a month vs a second) has no common duration grid, so it
  # raises rather than mixing calendar and fixed durations.
  def common_duration_unit(ou)
    unless CATimeUnitAlgebra.same_group?(unit, ou)
      raise ArgumentError,
            "cannot combine a #{unit} duration with a #{ou} duration " \
            "across the calendar/fixed boundary"
    end
    CATimeUnitAlgebra.finer(unit, ou)
  end
end

# Reads a time literal (Time / DateTime / Integer unix-seconds / String) into
# the pieces the CATime constructors need.  All parsing is UTC (an explicit
# offset is honoured; otherwise UTC) and DateTime-independent (Date._parse +
# a civil-date kernel).  Internal to the time surface: nothing here is part
# of the public API.
module CATimeLiteral
  module_function

  # Date fields of a String literal, UTC.  Ruby's Date._parse does not read
  # the calendar-grid forms CATime#to_s prints -- "2019-09" comes back as a
  # month of 20 with a zone, and a bare "2019" as a month and a day -- so
  # those two are read here and everything else is left to Date._parse.
  #
  # What Date._parse returns is then checked, because an out-of-range field
  # used to flow into the civil kernel and normalise into a different date:
  # "201909" is a valid YYMMDD to Ruby (2020-19-09, which landed on 2021-07),
  # and "2019-02-31" landed on 2019-03-03.  A missing finer field is not an
  # error -- a year or a year-month names the head of that period.
  def parse_date_fields(spec, format)
    h =
      if format                             then Date._strptime(spec, format)
      elsif spec =~ /\A(\d{4})-(\d{1,2})\z/ then { year: $1.to_i, mon: $2.to_i }
      elsif spec =~ /\A(\d{4})\z/           then { year: $1.to_i }
      else                                       Date._parse(spec)
      end
    unless h && h[:year]
      raise ArgumentError, "cannot parse time #{spec.inspect}"
    end
    y, m, d = h[:year], h[:mon] || 1, h[:mday] || 1
    unless (1..12).cover?(m) && Date.valid_date?(y, m, d, Date::GREGORIAN)
      raise ArgumentError,
            "cannot parse time #{spec.inspect}: it reads as year #{y}, " \
            "month #{m}, day #{d}, which is not a date"
    end
    h
  end
  private_class_method :parse_date_fields

  # Exact Rational seconds since the Unix epoch for a start literal (Time /
  # DateTime / Integer unix-seconds / String).  UTC default.
  def epoch_seconds(spec, format = nil)
    require 'date'
    require 'time'
    case spec
    when Time     then spec.to_r
    when Integer  then Rational(spec)
    when CATime::Element
      # A time element is already an instant, so it needs no parsing: a
      # fixed unit counts seconds directly, and a calendar one names the
      # first midnight of its granule (the same instant convert_instant!
      # gives it).  This is what lets floor / ceil / to_unit output feed
      # straight back into time_range / time_series / .time.
      if CATimeUnitAlgebra::FIXED.key?(spec.unit.base)
        Rational(spec.value) * spec.unit.tick_ratio
      else
        Rational(CATimeUnitAlgebra.calendar_days_since_epoch(CA_INT64([spec.value]),
                                             spec.unit)[0] * 86400)
      end
    when String
      h = parse_date_fields(spec, format)
      days = CATimeCivil.days_from_civil(CA_INT64([h[:year]]), CA_INT64([h[:mon] || 1]),
                               CA_INT64([h[:mday] || 1]))[0]
      sec  = Rational(days * 86400 + (h[:hour] || 0) * 3600 +
                      (h[:min] || 0) * 60 + (h[:sec] || 0))
      sec += h[:sec_fraction] if h[:sec_fraction]
      sec -= h[:offset]       if h[:offset]      # east-of-UTC offset -> UTC
      sec
    else
      if defined?(DateTime) && spec.is_a?(DateTime)
        spec.to_time.to_r
      else
        raise ArgumentError, "cannot parse time #{spec.class}"
      end
    end
  end

  # [year, month] (UTC) of a start literal, for a calendar-resolution grid.
  def year_month(spec, format = nil)
    require 'date'
    require 'time'
    case spec
    when Time    then t = spec.utc; [t.year, t.month]
    when Integer then t = Time.at(spec, in: 'UTC'); [t.year, t.month]
    when CATime::Element
      # A calendar element is a month ordinal already, so read it as one
      # rather than going out through Time (which a :Y / :M element would
      # have to re-derive).  Integer / and % floor, so a pre-epoch value
      # lands in the right month.
      case spec.unit.base
      when :M then mo = spec.value * spec.unit.count + 1970 * 12
                   [mo / 12, mo % 12 + 1]
      when :Y then [spec.value * spec.unit.count + 1970, 1]
      else         t = spec.to_time.utc; [t.year, t.month]
      end
    when String
      h = parse_date_fields(spec, format)
      [h[:year], h[:mon] || 1]
    else
      if defined?(DateTime) && spec.is_a?(DateTime)
        t = spec.to_time.utc; [t.year, t.month]
      else
        raise ArgumentError, "cannot parse time #{spec.class}"
      end
    end
  end

  # Tick index of `spec`'s instant on the `res` grid (floor toward the past).
  def tick_index(spec, res, format = nil)
    if CATimeUnitAlgebra::FIXED.key?(res.base)
      (epoch_seconds(spec, format) / res.tick_ratio).floor
    else
      y, m    = year_month(spec, format)
      months  = (y - 1970) * 12 + (m - 1)
      (Rational(months) / res.tick_ratio).floor
    end
  end

  # Single-literal build for {.time}: a 1-element CATime, honouring
  # the on_error policy (raise, or a masked cell).
  def to_time_array(literal, res, format, on_error)
    raw = CArray.int64(1)
    begin
      raw[0] = tick_index(literal, res, format)
    rescue ArgumentError, TypeError
      raise if on_error == :raise
      raw[0] = UNDEF
    end
    raw.time(unit: res)
  end
end

class CArray
  # Time is stored as an int64 tick index on a grid whose resolution is
  # `unit` (= a {CATime::Resolution}, tick = count * base).  The value
  # is the k-th tick since the Unix epoch (1970-01-01 UTC): e.g. unit
  # `"10 minutes"` value 3 = 1970-01-01T00:30:00Z.  Literals are read by
  # {CATimeLiteral} (UTC).

  # @overload time_range(start, last, unit:, step: nil, format: nil)
  #   Returns a {CATime} from `start` to `last` inclusive on the `unit`
  #   grid, spaced `step` apart.  `unit` is the resolution the result is
  #   stored on and `step` is the spacing, so an hourly grid sampled once a
  #   day is `unit: :h, step: "1 day"`.  With no `step` the spacing is one
  #   `unit` tick (consecutive ticks).  Off-grid endpoints floor to their
  #   bucket head (toward the past); the phase is anchored at `start`, and
  #   `last` is a bound rather than a member -- the series stops at the last
  #   step at or before it.
  #   @param start [Time, String, Integer, DateTime, CATime::Element] first
  #     instant.
  #   @param last [Time, String, Integer, DateTime, CATime::Element] last
  #     instant (inclusive).
  #   @param unit [Resolution, Symbol, String] grid resolution (tick).
  #   @param step [Resolution, Symbol, String, nil] spacing between elements
  #     (default: one `unit` tick).  Must be a whole multiple of `unit`.
  #   @param format [String, nil] optional strptime format for String inputs.
  #   @return [CATime]
  #   @raise [ArgumentError] when `step` is not a whole multiple of `unit`
  #     (including a calendar `step` on a fixed-length `unit`, e.g. a month
  #     step on an hour grid -- a month is not a fixed number of hours).
  def self.time_range(start, last, unit:, step: nil, format: nil)
    res    = CATime::Resolution.parse(unit)
    stride = step.nil? ? 1 :
               CATimeUnitAlgebra.multiple_factor(CATime::Resolution.parse(step), res)
    s = CATimeLiteral.tick_index(start, res, format)
    e = CATimeLiteral.tick_index(last,  res, format)
    n = e < s ? 0 : (e - s) / stride + 1
    CArray.int64(n) {|i| s + i * stride }.time(unit: res)
  end

  # @overload time_series(start, count:, unit:, step: nil, format: nil)
  #   Returns a {CATime} of `count` instants starting at `start` on the
  #   `unit` grid, spaced `step` apart.  `unit` is the resolution the result
  #   is stored on and `step` is the spacing, so an hourly grid sampled once
  #   a day is `unit: :h, step: "1 day"`.  With no `step` the spacing is one
  #   `unit` tick (consecutive ticks, as before).
  #   @param start [Time, String, Integer, DateTime, CATime::Element] first
  #     instant.
  #   @param count [Integer] number of elements.
  #   @param unit [Resolution, Symbol, String] grid resolution (tick).
  #   @param step [Resolution, Symbol, String, nil] spacing between elements
  #     (default: one `unit` tick).  Must be a whole multiple of `unit`.
  #   @param format [String, nil] optional strptime format for String inputs.
  #   @return [CATime]
  #   @raise [ArgumentError] when `step` is not a whole multiple of `unit`
  #     (including a calendar `step` on a fixed-length `unit`, e.g. a month
  #     step on an hour grid -- a month is not a fixed number of hours).
  def self.time_series(start, count:, unit:, step: nil, format: nil)
    res    = CATime::Resolution.parse(unit)
    stride = step.nil? ? 1 :
               CATimeUnitAlgebra.multiple_factor(CATime::Resolution.parse(step), res)
    s = CATimeLiteral.tick_index(start, res, format)
    CArray.int64(count) {|i| s + i * stride }.time(unit: res)
  end

  # @overload time(x, unit: :s, format: nil, on_error: :raise)
  #   Builds a {CATime} on the `unit` grid from time value(s).  `x`
  #   is either a single literal (Time / ISO 8601 String / Unix-seconds
  #   Integer / DateTime) — giving a 1-element result — or a CArray of such
  #   literals — giving a same-shape result parsed per cell.  Parsing is UTC
  #   and DateTime-independent.
  #
  #   A value that cannot be parsed raises by default (`on_error: :raise`);
  #   pass `on_error: :mask` to make it an UNDEF cell instead.  A masked /
  #   `nil` input cell is a *missing* value (not a parse failure) and always
  #   becomes UNDEF, regardless of `on_error`.
  #   @param x [Time, String, Integer, DateTime, CATime::Element, Array, CArray] a literal, a
  #     Ruby Array of literals, or a CArray of literals.
  #   @param unit [Resolution, Symbol, String] target grid resolution.
  #   @param format [String, nil] optional strptime format for String input.
  #   @param on_error [:raise, :mask] parse-failure policy (default `:raise`).
  #   @return [CATime] shape `[1]` for a literal, else `x`'s shape.
  #   @raise [ArgumentError] on an unparseable value when `on_error: :raise`.
  #
  # @example
  #   CArray.time("2024-06-15", unit: :D)                    # 1-element
  #   CArray.time(%w[2024-01-01 2024-02-01], unit: :D)       # Ruby Array
  #   CArray.time(CA_OBJECT(["2024-01-01", "oops"]), unit: :D, on_error: :mask)
  def self.time(x, unit: :s, format: nil, on_error: :raise)
    res = CATime::Resolution.parse(unit)
    unless %i[raise mask].include?(on_error)
      raise ArgumentError, "on_error: must be :raise or :mask (got #{on_error.inspect})"
    end
    x = CA_OBJECT(x) if x.is_a?(Array)   # Ruby Array of literals -> object CArray
    unless x.is_a?(CArray)
      return CATimeLiteral.to_time_array(x, res, format, on_error)
    end
    raw = CArray.int64(*x.shape)
    x.each_index do |*idx|
      s = x[*idx]
      if s == UNDEF || s.nil?
        raw[*idx] = UNDEF        # missing input -> missing output (no phantom epoch)
        next
      end
      begin
        raw[*idx] = CATimeLiteral.tick_index(s, res, format)
      rescue ArgumentError, TypeError
        raise if on_error == :raise
        raw[*idx] = UNDEF        # opt-in parse-mask
      end
    end
    raw.time(unit: res)
  end

  # @overload time(unit: :ns, origin: nil)
  #   Returns `self` as a {CATime} on the `unit` grid.  With `origin`
  #   nil, `self`'s int64 values are taken as tick indices already anchored
  #   to the Unix epoch (zero-copy Face wrap).  With `origin` given, `self`'s
  #   indices are relative to `origin` and are rebased to the epoch (a new
  #   int64 array is built; the origin is not stored).
  #   @param unit [Resolution, Symbol, String] grid resolution.
  #   @param origin [Time, String, Integer, DateTime, CATime::Element, nil] base instant that
  #     `self`'s indices are counted from (default: the Unix epoch).
  #   @return [CATime]
  #   @note An `int64` receiver is wrapped zero-copy.  A narrower integer type
  #     is widened to `int64` first (a copy); a `Float` / non-integer type
  #     raises (cast it explicitly if the truncation is intended).
  def time(unit: :ns, origin: nil)
    res = CATime::Resolution.parse(unit)
    src = as_int64_time_storage
    if origin.nil?
      CATime.wrap(src, unit: res)
    else
      o = CATimeLiteral.tick_index(origin, res)
      (src + o).time(unit: res)
    end
  end

  # @overload timedelta(unit: :ns)
  #   Returns `self` re-wrapped as a zero-copy {CATimedelta} view
  #   with the given `unit`.
  #   @param unit [Resolution, Symbol, String] duration resolution.
  #   @return [CATimedelta]
  #   @note An `int64` receiver is wrapped zero-copy; a narrower integer type
  #     is widened to `int64` first (a copy); a `Float` / non-integer raises.
  def timedelta(unit: :ns)
    CATimedelta.wrap(as_int64_time_storage, unit: unit)
  end

  # Coerce the receiver to the int64 storage a time / timedelta Face needs:
  # int64 passes through (zero-copy), a narrower integer type widens losslessly
  # to int64 (a copy), and any non-integer (Float, boolean, object, ...) raises.
  def as_int64_time_storage
    return self if data_type == CA_INT64
    unless integer?
      raise TypeError,
            "CATime / CATimedelta storage must be int64; a #{data_type} " \
            "array cannot be wrapped (cast it explicitly, e.g. " \
            "arr.int64.time(...), if a lossy conversion is intended)"
    end
    int64
  end
  private :as_int64_time_storage
end

# ============================================================================
# timestep system (P1/P2 integer path)
#
# Projects an absolute time onto an integer "step index" -- the k-th
# fixed-width bucket of `step` counted from `origin` -- and the inverse /
# rounding / on-grid operators built on it.  All storage-domain int64 and
# vectorized; the crown jewel is that bucketing, matching, and positional
# addressing across differently-scaled series all become integer arithmetic.
#
# Integer path covers: fixed-length step on fixed-length storage, and Y/M
# step on Y/M storage (:M storage already encodes a linear month ordinal, so
# it floor-divides identically).  The calendar path (Y/M step on sub-day
# storage, via civil-date algebra) is P3 and currently raises.
# See devel/PROPOSAL_DATETIME64_STEP_SYSTEM.md.
# ============================================================================

# Places a bucket grid on a storage resolution: resolves a timestep into whole
# storage ticks, resolves an origin into a tick count (or a month ordinal on
# the calendar path), and guards both against int64 overflow.  Internal to the
# time surface: nothing here is part of the public API.
module CATimeGrid
  module_function

  # Base units that are day-or-finer (a period head is representable exactly;
  # the civil path targets these for a calendar bucket).
  SU_LE_DAY = %i[D h m s ms us ns ps fs as].freeze

  INT64_MIN = -(2**63)
  INT64_MAX =  2**63 - 1

  # Raise (rather than let an int64 CArray operand silently wrap) if a
  # Ruby-domain quantity is out of int64 range.  Returns the value on success
  # so it composes inline.
  def check_int64_range(v, what)
    if v < INT64_MIN || v > INT64_MAX
      raise RangeError,
            "time step: #{what} = #{v} overflows int64 " \
            "(the storage unit is too fine for this step / origin / span; " \
            "use a coarser unit)"
    end
    v
  end

  # Return [mul, step_ticks, origin_ticks] (all Integer) for the integer
  # path -- step_ticks and origin_ticks in numerator ticks, the finer of
  # the storage and step grids (see #resolve_timestep_grid).  The calendar path is
  # handled by the caller.
  def resolve_integer_grid(step_res, storage_res, origin)
    mul, step_ticks = resolve_step_scale(step_res, storage_res)
    [mul, step_ticks, resolve_origin_ticks(origin, step_res,
                                            mul == 1 ? storage_res : step_res)]
  end

  # Storage ticks per day of `storage_res` (must be a whole number, else the
  # storage grid does not tile a day -- a calendar bucket is unrepresentable).
  def ticks_per_day(storage_res)
    r = CATimeUnitAlgebra.ratio(CATime::Resolution.new(1, :D), storage_res)
    unless r.denominator == 1
      raise ArgumentError,
            "cannot place a calendar bucket on storage resolution " \
            "#{storage_res} (its tick does not tile a day)"
    end
    check_int64_range(r.numerator, "ticks per day for #{storage_res}")
  end

  # Storage ticks of the bucket head at timestep `k` (int64 CArray) for a
  # calendar bucket: ym0 + k*count months -> day 1 of that month -> ticks.
  def calendar_bucket_head_ticks(k, st, storage_res, origin)
    tpd   = ticks_per_day(storage_res)
    count = st.count * (st.base == :Y ? 12 : 1)
    ym0   = origin_month_ordinal(origin)
    ymk   = ym0 + k * count
    yy    = CATimeCivil.floor_divide(ymk, 12)
    mm    = ymk - yy * 12 + 1
    CATimeCivil.days_from_civil(yy, mm, CArray.int64(*k.shape) { 1 }) * tpd
  end

  # Month ordinal (year*12 + month-1) of origin; day / time ignored.
  # Default (nil) is the epoch month 1970-01.
  def origin_month_ordinal(origin)
    return 1970 * 12 if origin.nil?
    y, m = check_calendar_origin(origin, nil)
    y * 12 + (m - 1)
  end

  # [mul, step_ticks] for the integer path, or :civil (calendar bucket on
  # day-or-finer storage), or raise.  Bucket arithmetic runs in the finer of
  # the two grids, so exactly one of the pair is > 1:
  #   - bucket at or coarser than the storage tick (a :h bucket on :s
  #     storage) -> [1, N]: N storage ticks per bucket.
  #   - bucket finer than the storage tick (a :h bucket on :D storage) ->
  #     [N, 1]: one storage tick spans N buckets exactly, so a timestep is a
  #     plain widening.  This needs the storage tick to be a *whole* multiple
  #     of the bucket tick; a partial multiple ("90 minutes" storage against
  #     an :h bucket) has no integer timestep and raises.
  def resolve_step_scale(step_res, storage_res)
    r = CATimeUnitAlgebra.ratio(step_res, storage_res)  # storage ticks / step tick
    if r
      what = "bucket #{step_res} in ticks of #{storage_res}"
      return [1, check_int64_range(r.numerator, what)] if r.denominator == 1
      return [check_int64_range(r.denominator, what), 1] if r.numerator == 1
    end
    if CATimeUnitAlgebra::CALENDAR.key?(step_res.base) && SU_LE_DAY.include?(storage_res.base)
      return :civil
    end
    raise ArgumentError,
          "cannot express bucket #{step_res} on storage resolution #{storage_res} " \
          "(neither is a whole multiple of the other)"
  end

  # origin -> integer tick count in storage ticks.  Default (nil) is the
  # epoch, except a week bucket defaults to ISO Monday (1970-01-05).  A lossy
  # conversion (origin not landing exactly on the storage grid) raises; a
  # bare Integer is rejected (epoch-dependent, ambiguous).
  def resolve_origin_ticks(origin, step_res, storage_res)
    if origin.nil?
      if step_res.base == :W && SU_LE_DAY.include?(storage_res.base)
        return check_int64_range(ticks_per_day(storage_res) * 4,
                      "ISO-Monday week origin in ticks of #{storage_res}")
      end
      return 0
    end
    if CATimeUnitAlgebra::FIXED.key?(storage_res.base)
      secs = origin_seconds_exact(origin)
      tick = secs / storage_res.tick_ratio               # Rational
      unless tick.denominator == 1
        raise ArgumentError,
              "origin #{origin.inspect} is not representable losslessly " \
              "in storage resolution #{storage_res} (would truncate the grid phase)"
      end
      check_int64_range(tick.numerator, "origin #{origin.inspect} in ticks of #{storage_res}")
    else                                                 # :Y / :M storage
      y, m = check_calendar_origin(origin, storage_res)
      ord  = storage_res.base == :Y ? (y - 1970) : (y * 12 + (m - 1) - 1970 * 12)
      if storage_res.count > 1
        unless (ord % storage_res.count).zero?
          raise ArgumentError,
                "origin #{origin.inspect} is not on the #{storage_res} grid"
        end
        ord /= storage_res.count
      end
      ord
    end
  end

  # Exact Rational seconds since the Unix epoch for a fixed-storage origin.
  # Everything but a bare Integer goes through the shared entry point, so
  # an origin reads the same here as it does for a start literal.
  def origin_seconds_exact(origin)
    case origin
    when Integer
      raise ArgumentError,
            "origin: a bare Integer is ambiguous (epoch-dependent); pass a " \
            "Time / String / CATime scalar"
    else
      CATimeLiteral.epoch_seconds(origin)  # Time / String / DateTime / Element
    end
  end

  # Whether `origin` sits exactly on the head of its month (the 1st at
  # 00:00 UTC).  A calendar grid is addressed by month ordinal, so its
  # bucket heads are month heads and nothing else; an origin anywhere in
  # between names a bucket that does not exist.
  def origin_on_month_head?(origin)
    # A calendar element is a month head by construction, and the shared
    # entry point says so by handing back that midnight -- no branch here
    # has to know it.
    secs = CATimeLiteral.epoch_seconds(origin)
    y, m = origin_year_month(origin)
    head = CATimeCivil.days_from_civil(CA_INT64([y]), CA_INT64([m]), CA_INT64([1]))[0]
    secs == head * 86400
  end

  # Raise unless `origin` can be the head of bucket 0 on a calendar grid:
  # it has to be a month head, and a :Y tick starts in January.  The day
  # and time would otherwise be dropped silently -- the same loss a fixed
  # unit already refuses (see resolve_origin_ticks).
  def check_calendar_origin(origin, storage_res)
    return if origin.nil?
    y, m = origin_year_month(origin)
    unless origin_on_month_head?(origin)
      raise ArgumentError,
            "origin #{origin.inspect} is not a month head: a calendar grid " \
            "is addressed by month, so its origin must be the 1st at 00:00"
    end
    if storage_res && storage_res.base == :Y && m != 1
      raise ArgumentError,
            "origin #{origin.inspect} is not on the #{storage_res} grid " \
            "(a #{storage_res} tick starts in January)"
    end
    [y, m]
  end

  # [year, month] of a calendar-storage origin (finer fields ignored).
  def origin_year_month(origin)
    case origin
    when Integer
      raise ArgumentError,
            "origin: a bare Integer is ambiguous (epoch-dependent); pass a " \
            "Time / String / CATime scalar"
    else
      CATimeLiteral.year_month(origin)  # Time / String / DateTime / Element
    end
  end
end

class CATime
  # A tick resolution: `count` ticks of a `base` unit.  The human surface is
  # a String ("3 hours" / "1 month"); a bare Symbol (:h) is the count-1
  # shorthand over the base-unit vocabulary.  It names both a storage tick
  # (= the grid a CATime is stored on) and a coarser bucket for the
  # floor / timesteps family.  Value object: frozen, value-equal, hashable.
  class Resolution
    attr_reader :count, :base

    # Long / abbreviated unit words -> base unit symbol.  Calendar words
    # (ayear etc.) are intentionally dropped (standard calendar only).
    WORDS = {
      "year" => :Y, "years" => :Y, "yr" => :Y, "yrs" => :Y,
      "month" => :M, "months" => :M, "mon" => :M, "mons" => :M,
      "week" => :W, "weeks" => :W,
      "day" => :D, "days" => :D,
      "hour" => :h, "hours" => :h, "hr" => :h, "hrs" => :h,
      "minute" => :m, "minutes" => :m, "min" => :m, "mins" => :m,
      "second" => :s, "seconds" => :s, "sec" => :s, "secs" => :s,
      "millisecond" => :ms, "milliseconds" => :ms, "msec" => :ms, "msecs" => :ms,
      "microsecond" => :us, "microseconds" => :us, "usec" => :us, "usecs" => :us,
      "nanosecond" => :ns, "nanoseconds" => :ns,
      "picosecond" => :ps, "picoseconds" => :ps,
      "femtosecond" => :fs, "femtoseconds" => :fs,
      "attosecond" => :as, "attoseconds" => :as,
    }.freeze

    # Single-letter / short symbols accepted as the count-1 shorthand.  These
    # are the base-unit letters (case-sensitive: :m minute vs :M month).
    SYMBOLS = %i[Y M W D h m s ms us ns ps fs as].freeze

    # Coerces `spec` into a {Resolution}: a Resolution passes through, a base
    # unit Symbol becomes count 1, and a String such as `"10 minutes"` is parsed.
    # @param spec [Resolution, Symbol, String]
    # @return [Resolution]
    # @raise [ArgumentError] when `spec` names no known unit.
    def self.parse(spec)
      case spec
      when Resolution then spec
      when Symbol
        unless SYMBOLS.include?(spec)
          raise ArgumentError, "invalid unit #{spec.inspect} " \
                "(one of #{SYMBOLS.map(&:inspect).join(', ')})"
        end
        new(1, spec)
      when String
        # Strict grammar: "<unit>" (count 1) or "<n> <unit>" (whitespace
        # required -- compact "3h" is rejected).
        m = spec.strip.match(/\A(?:(\d+)\s+)?([A-Za-z]+)\z/)
        unless m && WORDS.key?(m[2].downcase)
          raise ArgumentError, "invalid unit spec #{spec.inspect} " \
                "(use e.g. \"3 hours\" / \"1 month\", or a unit Symbol)"
        end
        new(m[1] ? Integer(m[1]) : 1, WORDS[m[2].downcase])
      else
        raise ArgumentError, "unit spec must be a String / Symbol / Resolution " \
              "(got #{spec.class})"
      end
    end

    def initialize(count, base)
      raise ArgumentError, "unit count must be >= 1 (got #{count})" if count < 1
      # Only integer multiples are well-defined (calendar Y/M bases are
      # month-ordinal linear, so a fractional multiple has no meaning).
      # Resolution.parse always hands in an Integer; a fractional count via
      # a direct `new` is not guarded here.
      @count = count
      @base  = base
      freeze
    end

    # seconds- (fixed base) or months- (calendar base) per tick (Rational).
    def tick_ratio
      count * CATimeUnitAlgebra.base_ratio(base)
    end

    # @return [Boolean] whether `other` is the same count and base unit.
    def ==(other) = other.is_a?(Resolution) && other.count == count && other.base == base
    alias eql? ==
    # @return [Integer] a hash consistent with #==.
    def hash = [count, base].hash
    # @return [String] e.g. `"h"` for a count of 1, `"10 minutes"` otherwise.
    def to_s = count == 1 ? base.to_s : "#{count} #{base}"
    # @return [String]
    def inspect = "#<CATime::Resolution #{count} #{base}>"
  end

  # @overload timesteps(unit: self.unit, origin: nil)
  #   Returns the integer timestep of every element: the k-th `unit`-wide
  #   bucket counted from `origin` (floor toward the past, so pre-`origin`
  #   elements get a negative index -- a normal value, not masked).  The
  #   result is an int64 CArray; the input mask propagates.  With no `unit`
  #   the bucket is the storage resolution itself, so the result is a copy of
  #   the raw tick indices since the epoch (the same values as
  #   {#ticks}, but a fresh array rather than the live storage).
  #   @param unit [String, Symbol, Resolution] bucket resolution
  #     (default: this array's own storage resolution).
  #   @param origin [Time, String, CATime::Element, DateTime, nil] head of
  #     bucket 0 (default: the Unix epoch, or ISO Monday for a week bucket
  #     on day-or-finer storage -- a week grid counts from the epoch
  #     Thursday and cannot hold a Monday, so it keeps its own ticks).
  #     It has to be a bucket head itself: on a calendar grid, the 1st at
  #     00:00.
  #   @return [CArray] int64 timesteps.
  #   @raise [ArgumentError] on a sub-resolution / unrepresentable (unit,
  #     storage-resolution) pair or a lossy origin.
  def timesteps(unit: self.unit, origin: nil)
    g = resolve_timestep_grid(unit, origin)
    return calendar_bucket(:index, g[1], origin) if g[0] == :civil
    su, mul, step_ticks, o = g
    raise_if_int64_overflow(su, mul, o)
    d = storage_ticks_in_numerator_grid(mul) - o
    q = d / step_ticks
    q - (d - q * step_ticks).lt(0)      # floor-div correction (%-independent)
  end

  # @overload floor(unit:, origin: nil)
  #   Returns each element floored to its bucket head (toward the past), as a
  #   {CATime} in the same storage resolution.
  #   @param unit [String, Symbol, Resolution] bucket resolution.
  #   @param origin [Time, String, CATime::Element, DateTime, nil] head of
  #     bucket 0 (default: the Unix epoch, or ISO Monday for a week bucket
  #     on day-or-finer storage -- a week grid counts from the epoch
  #     Thursday and cannot hold a Monday, so it keeps its own ticks).
  #     It has to be a bucket head itself: on a calendar grid, the 1st at
  #     00:00.
  #   @return [CATime]
  def floor(unit:, origin: nil)
    g = resolve_timestep_grid(unit, origin)
    return calendar_bucket(:floor, g[1], origin) if g[0] == :civil
    su, mul, step_ticks, o = g
    raise_if_int64_overflow(su, mul, o, step_ticks, :floor)
    d = storage_ticks_in_numerator_grid(mul) - o
    q = d / step_ticks
    q = q - (d - q * step_ticks).lt(0)
    bucket_head_as_time(o + q * step_ticks, mul, su)
  end

  # @overload ceil(unit:, origin: nil)
  #   Returns each element raised to its bucket head at or after it (an
  #   element already on a boundary maps to itself), as a {CATime}.
  #   @return [CATime]
  def ceil(unit:, origin: nil)
    g = resolve_timestep_grid(unit, origin)
    return calendar_bucket(:ceil, g[1], origin) if g[0] == :civil
    su, mul, step_ticks, o = g
    raise_if_int64_overflow(su, mul, o, step_ticks, :ceil)
    n  = storage_ticks_in_numerator_grid(mul)
    d  = n - o
    q  = d / step_ticks
    q  = q - (d - q * step_ticks).lt(0)
    fl = o + q * step_ticks
    bucket_head_as_time(fl + step_ticks * n.ne(fl), mul, su)
  end

  # @overload round(unit:, origin: nil)
  #   Returns each element rounded to its nearest bucket head (ties toward
  #   the future, matching `snap` :round), as a {CATime}.  Exact for
  #   odd `step_ticks` (no half-tick loss).  For a calendar bucket the nearest
  #   head is by absolute tick distance (month lengths vary), ties toward the
  #   future.
  #   @return [CATime]
  def round(unit:, origin: nil)
    g = resolve_timestep_grid(unit, origin)
    return calendar_bucket(:round, g[1], origin) if g[0] == :civil
    su, mul, step_ticks, o = g
    raise_if_int64_overflow(su, mul, o, step_ticks, :round)
    d = storage_ticks_in_numerator_grid(mul) - o
    q = d / step_ticks
    q = q - (d - q * step_ticks).lt(0)            # floor bucket
    r = d - q * step_ticks                        # 0 <= r < step_ticks
    q = q + r.ge((step_ticks + 1) / 2)            # ties -> future; no 2*d / 2*r
    bucket_head_as_time(o + q * step_ticks, mul, su)
  end

  # @overload is_righttime(unit:, origin: nil)
  #   Returns a boolean CArray flagging elements that land exactly on a bucket
  #   head.  Use as an assertion before matching to catch off-grid series (a
  #   timesteps match is "same bucket", not "same instant").
  #   @param unit [String, Symbol, Resolution] bucket resolution.
  #   @param origin [Time, String, CATime::Element, DateTime, nil] head of
  #     bucket 0 (default: the Unix epoch, or ISO Monday for a week bucket
  #     on day-or-finer storage -- a week grid counts from the epoch
  #     Thursday and cannot hold a Monday, so it keeps its own ticks).
  #     It has to be a bucket head itself: on a calendar grid, the 1st at
  #     00:00.
  #   @return [CArray] boolean.
  def is_righttime(unit:, origin: nil)
    g = resolve_timestep_grid(unit, origin)
    return calendar_bucket(:on, g[1], origin) if g[0] == :civil
    su, mul, step_ticks, o = g
    raise_if_int64_overflow(su, mul, o)
    d = storage_ticks_in_numerator_grid(mul) - o
    q = d / step_ticks
    (d - q * step_ticks).eq(0)
  end

  # @overload from_timesteps(k, unit:, origin: nil)
  #   Inverse of {#timesteps}: returns the bucket-head time for timestep
  #   `k`.  Use to relabel a `group_by(timesteps)` result, generate a
  #   regular grid, or as a timesteps round-trip oracle.
  #   A scalar `k` returns a {Element}; a CArray `k` returns a {CATime}.
  #
  #   The result is stored on the `unit` grid, except a week bucket, which
  #   is stored on `:D`.  A week grid counts from the epoch (a Thursday) and
  #   so cannot hold its own bucket head: the head is the ISO Monday, four
  #   days off every week tick.  Days hold it exactly, so a `:W` bucket
  #   answers on the day grid and the round trip against a day-or-finer
  #   series is exact.  `unit:` names the bucket here, the way it does for
  #   {#floor} / {#ceil} -- not the storage the answer lands on.
  #   @param k [Integer, CArray] timestep / timesteps.
  #   @param unit [String, Symbol, Resolution] bucket resolution.
  #   @param origin [Time, String, CATime::Element, DateTime, nil] head of
  #     bucket 0 (default: the Unix epoch, or ISO Monday for a week bucket).
  #     It has to be a bucket head itself: on a calendar grid, the 1st at
  #     00:00.
  #   @return [Element, CATime] on the `unit` grid (`:D` for a week bucket).
  def self.from_timesteps(k, unit:, origin: nil)
    res = Resolution.parse(unit)
    out = res.base == :W ? Resolution.new(1, :D) : res
    kk  = k.is_a?(CArray) ? k.int64 : CArray.int64(1) { Integer(k) }
    _mul, step_ticks, o = CATimeGrid.resolve_integer_grid(res, out, origin)
    raw = o + kk * step_ticks
    k.is_a?(CArray) ? raw.time(unit: out) : Element.new(raw[0], out)
  end

  private

  # Resolve the grid for an instance: [storage_res, mul, step_ticks,
  # origin_ticks] for the integer path, or [:civil, bucket_res] for the
  # calendar path.  Bucket arithmetic runs in the *numerator* grid -- the
  # finer of the storage tick and the bucket tick -- so `mul` (storage ticks
  # per numerator tick) is 1 for a bucket at or coarser than the storage
  # tick, and the widening factor for a finer bucket.  `origin_ticks` is
  # likewise in numerator ticks.
  def resolve_timestep_grid(step, origin)
    storage_res = unit
    step_res    = Resolution.parse(step)
    scale = CATimeGrid.resolve_step_scale(step_res, storage_res)
    return [:civil, step_res] if scale == :civil
    mul, step_ticks = scale
    num_res = mul == 1 ? storage_res : step_res
    o = CATimeGrid.resolve_origin_ticks(origin, step_res, num_res)
    [storage_res, mul, step_ticks, o]
  end

  # Storage ticks lifted into the numerator grid (see {#resolve_timestep_grid}).
  def storage_ticks_in_numerator_grid(mul)
    mul == 1 ? parent : CATimeUnitAlgebra.widen(parent, mul)
  end

  # A bucket head computed in numerator ticks, back as a {CATime} in the
  # storage resolution.  The division is exact: a numerator grid finer than
  # the storage tick only arises when every element already sits on it, so
  # each head is a whole number of storage ticks.
  def bucket_head_as_time(head, mul, su)
    (mul == 1 ? head : head / mul).time(unit: su)
  end

  # Base units where int64 range is small enough that array-domain arithmetic
  # (parent - o, 2*d) can overflow for a realistic time span; coarser
  # bases cannot, so the range guard is skipped for them (zero cost on the
  # common :s / :h / :D / :M path).
  FINE_UNITS = %i[us ns ps fs as].freeze

  # Raise (rather than silently wrap) if the integer-path arithmetic would
  # overflow int64.  Checks `parent - o`, and -- when `kind` is a bucket op
  # (:floor / :ceil / :round) -- the reconstructed bucket head `o + q*step`,
  # which ceil / round can push up to one step beyond the input range.  Both
  # extremes are computed in the Ruby (bignum) domain from the storage
  # min / max, so the check is O(1) beyond the two reduces.
  #
  # Gated to fine units, where the int64 span is genuinely tight, plus every
  # widened (`mul` > 1) grid, where a coarse storage unit is lifted into a
  # much finer one; a pathological raw value wrapped in a coarse-unit Face is
  # not guarded (the gate is a value-range heuristic, not a proof).
  #
  # min / max skip masked cells, so a masked cell does not decide the range
  # (it carries no time), and answer UNDEF when there is nothing to bound --
  # an empty array, or one whose every cell is masked.
  def raise_if_int64_overflow(su, mul, o, step_ticks = nil, kind = nil)
    return unless mul > 1 or FINE_UNITS.include?(su.base)
    min = parent.min
    return if min == UNDEF
    lo  = Integer(min) * mul
    hi  = Integer(parent.max) * mul
    chk = ->(v, w) { CATimeGrid.check_int64_range(v, w) }
    chk.(lo, "ticks in bucket resolution")
    chk.(hi, "ticks in bucket resolution")
    chk.(lo - o, "parent - origin")
    chk.(hi - o, "parent - origin")
    if kind
      chk.(bucket_head_ticks(lo, o, step_ticks, kind), "bucket head")
      chk.(bucket_head_ticks(hi, o, step_ticks, kind), "bucket head")
    end
  end

  # Ruby-domain (exact bignum) bucket head for a single storage value -- the
  # scalar mirror of the array floor / ceil / round, used only by the overflow
  # guard.  Ruby Integer `/` and `%` floor, so `(v - o) / s` is the floor
  # bucket directly.
  def bucket_head_ticks(v, o, s, kind)
    fq = (v - o) / s
    case kind
    when :floor then o + fq * s
    when :ceil  then h = o + fq * s; v == h ? h : h + s
    when :round then r = (v - o) - fq * s; o + (fq + (r >= (s + 1) / 2 ? 1 : 0)) * s
    end
  end

  # Days since the Unix epoch of the date each element represents (mask
  # propagates).  Calendar units (:Y / :M) resolve to day 1 of their year /
  # month; a week is 7 days; day-or-finer units floor to the day.
  def days_since_epoch
    res = unit
    case res.base
    when :Y
      ones = CArray.int64(*shape) { 1 }
      CATimeCivil.days_from_civil(parent * res.count + 1970, ones, ones)
    when :M
      mo = parent * res.count + 1970 * 12
      y  = CATimeCivil.floor_divide(mo, 12)
      m  = mo - y * 12 + 1
      CATimeCivil.days_from_civil(y, m, CArray.int64(*shape) { 1 })
    when :W then parent * res.count * 7
    when :D then parent * res.count
    else                                                   # fixed sub-day storage
      day = CATime::Resolution.new(1, :D)
      r   = CATimeUnitAlgebra.ratio(day, res)          # storage ticks per day
      if r.denominator == 1
        CATimeCivil.floor_divide(parent, r.numerator)
      else                                                 # non-day-aligned tick
        tr = res.tick_ratio                                # seconds / tick
        CATimeCivil.floor_divide(parent * tr.numerator, 86400 * tr.denominator)
      end
    end
  end

  # Clock field `fu` (:h / :m / :s): the field-of-its-parent value (hour of
  # day, minute of hour, second of minute).  Computed as the epoch-relative
  # `fu` index of each element modulo its cycle, so a storage tick finer OR
  # coarser than `fu` both resolve exactly (a 10-minute grid gives minute 0 /
  # 10 / 20 / ...; a day grid collapses hour / minute / second to 0).  A
  # calendar-storage element has no intra-day field, so it collapses to 0.
  def clock_field(fu)
    r = CATimeUnitAlgebra.ratio(unit, CATime::Resolution.new(1, fu))  # fu ticks / storage tick
    return parent * 0 if r.nil?                            # calendar storage: no clock field
    fi = r.denominator == 1 ? parent * r.numerator         # epoch-relative fu index
                            : CATimeCivil.floor_divide(parent * r.numerator, r.denominator)
    cycle = fu == :h ? 24 : 60                             # hour 0..23; min/sec 0..59
    fi - CATimeCivil.floor_divide(fi, cycle) * cycle  # floor-mod (handles pre-epoch)
  end

  # Calendar path (Y/M step on day-or-finer storage) via civil-date integer
  # algebra: floor toward the past by month ordinal, no boundary array / no
  # min-max, O(N) branch-free, origin-absolute k (negative pre-origin).  The
  # origin's day / time is ignored (month ordinal only, per the design).
  # `kind`: :index / :floor / :ceil / :round / :on.
  def calendar_bucket(kind, st, origin)
    su    = unit                                           # storage Resolution
    count = st.count * (st.base == :Y ? 12 : 1)            # bucket in months
    ym0   = CATimeGrid.origin_month_ordinal(origin)
    days  = days_since_epoch                               # count-folded day index
    y, m  = CATimeCivil.civil_from_days(days)
    ym    = y * 12 + (m - 1)
    k     = CATimeCivil.floor_divide(ym - ym0, count)
    return k if kind == :index
    head = CATimeGrid.calendar_bucket_head_ticks(k, st, su, origin)
    return head.time(unit: su) if kind == :floor
    return parent.eq(head)          if kind == :on
    head_next = CATimeGrid.calendar_bucket_head_ticks(k + 1, st, su, origin)
    sel =                                # boolean 0/1: pick head_next?
      case kind
      when :ceil  then parent.ne(head)                 # on-boundary keeps head
      when :round then (head_next - parent).le(parent - head)  # nearest, ties -> future
      end
    (head + (head_next - head) * sel).time(unit: su)
  end

end

# The view-creating method lift hook lives in the C layer (= subclass-
# agnostic): each view-creating C method (rb_ca_transpose / rb_ca_reshape
# / etc.) ends with `if (ca_is_face(ca)) obj = ca_face_lift(obj, self);`,
# so a view of a Face re-lifts to the same Face class. See the relevant C
# source (ext/ca_obj_transpose.c etc.) for details.
