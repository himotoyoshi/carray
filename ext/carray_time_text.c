#include "carray.h"
#include "carray_internal.h"

/* ------------------------------------------------------------------------
   Reading year-first dates and times from text

   A cell is read when it is written year first:

     date    YYYY sep M sep D           sep is '-' or '/', the same twice;
                                        month and day take one or two digits
     time    ( 'T' | ' '+ ) h ':' mm ( ':' ss ( ( '.' | ',' ) fraction )? )?
                                        hour takes one or two digits,
                                        fraction one to nine
     zone    ' '? ( 'Z' | ( '+' | '-' ) hh ( ':'? mm )? )   after a time only

   Surrounding ASCII whitespace is ignored.  A time without a zone is UTC,
   and a zone is folded into UTC.  Nothing written in another order is read:
   whether "01/02/2024" is January or February cannot be told from the text.

   Read wide (when the caller has said the column is time), the year may
   also carry a sign and more than four digits, and a date may stop after
   the month ("2024-01") or the year ("2024", four digits unless signed) --
   what CATime writes for a unit of months or years, or for a year past
   9999.  Text is not read
   wide when it is being tried as time, since "2024" is as likely a number.

   The unit of the result is the finest the text shows, unless one is
   given: :D when no cell has a time of day, :s with one, and :ms / :us /
   :ns when a fraction of a second has up to 3 / 6 / 9 digits; read wide,
   :M when no cell has a day and :Y when none has a month either.
   ------------------------------------------------------------------------ */

enum {
  CA_TIME_TEXT_OK = 0,
  CA_TIME_TEXT_BLANK,
  CA_TIME_TEXT_UNREADABLE
};

typedef struct {
  int64_t days;        /* days since 1970-01-01 */
  int64_t nsod;        /* nanoseconds into that day, 0 <= nsod < 86400e9 */
  int     clock;       /* a time of day is written */
  int     fraction;    /* digits written after the seconds */
  int     coarse;      /* 0 a day is written, 1 only a month, 2 only a year */
  int64_t months;      /* months since 1970-01 */
} ca_time_text_t;

static const int64_t ca_ns_per_day = INT64_C(86400000000000);

static int
ca_time_text_is_space (char c)
{
  return c == ' ' || c == '\t' || c == '\n' || c == '\r'
         || c == '\v' || c == '\f';
}

/* Read min..max digits at s[*i] into *out. */
static int
ca_time_text_digits (const char *s, long n, long *i, int min, int max,
                     int64_t *out)
{
  int64_t v = 0;
  int count = 0;
  while ( *i < n && count < max && s[*i] >= '0' && s[*i] <= '9' ) {
    v = v * 10 + ( s[*i] - '0' );
    (*i)++;
    count++;
  }
  if ( count < min ) {
    return 0;
  }
  if ( *i < n && s[*i] >= '0' && s[*i] <= '9' ) {
    return 0;                       /* more digits than the field takes */
  }
  *out = v;
  return count;
}

static int
ca_time_text_leap (int64_t y)
{
  return ( y % 4 == 0 && y % 100 != 0 ) || y % 400 == 0;
}

static int
ca_time_text_month_days (int64_t y, int64_t m)
{
  static const int days[12] = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
  return ( m == 2 && ca_time_text_leap(y) ) ? 29 : days[m - 1];
}

/* Days since 1970-01-01 of a proleptic Gregorian date. */
static int64_t
ca_time_text_days_from_civil (int64_t y, int64_t m, int64_t d)
{
  int64_t era, yoe, doy, doe;
  y -= ( m <= 2 );
  era = ( y >= 0 ? y : y - 399 ) / 400;
  yoe = y - era * 400;
  doy = ( 153 * ( m > 2 ? m - 3 : m + 9 ) + 2 ) / 5 + d - 1;
  doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
  return era * 146097 + doe - 719468;
}

static int
ca_time_text_read (VALUE str, ca_time_text_t *t, int wide)
{
  const char *s = RSTRING_PTR(str);
  long n = RSTRING_LEN(str);
  long i = 0;
  int64_t year, mon, day, hour = 0, min = 0, sec = 0, frac_ns = 0;
  int64_t offset = 0;
  int year_digits;
  char sep;

  while ( n > 0 && ca_time_text_is_space(s[0]) ) {
    s++;
    n--;
  }
  while ( n > 0 && ca_time_text_is_space(s[n-1]) ) {
    n--;
  }
  if ( n == 0 ) {
    return CA_TIME_TEXT_BLANK;
  }

  t->clock = 0;
  t->fraction = 0;
  t->coarse = 0;

  if ( wide ) {
    int sign = 0;
    if ( s[i] == '+' || s[i] == '-' ) {
      sign = ( s[i] == '-' ) ? -1 : 1;
      i++;
    }
    year_digits = ca_time_text_digits(s, n, &i, 4, 12, &year);
    if ( year_digits == 0 ) {
      return CA_TIME_TEXT_UNREADABLE;
    }
    if ( sign < 0 ) {
      year = -year;
    }
    /* A year alone is four digits unless signed: "20240101" is a date
       written without separators, which is not read. */
    if ( i == n && year_digits > 4 && sign == 0 ) {
      return CA_TIME_TEXT_UNREADABLE;
    }
  }
  else if ( ca_time_text_digits(s, n, &i, 4, 4, &year) == 0 ) {
    return CA_TIME_TEXT_UNREADABLE;
  }
  if ( wide && i == n ) {
    t->coarse = 2;
    t->months = ( year - 1970 ) * 12;
    t->days = ca_time_text_days_from_civil(year, 1, 1);
    t->nsod = 0;
    return CA_TIME_TEXT_OK;
  }
  if ( i >= n || ( s[i] != '-' && s[i] != '/' ) ) {
    return CA_TIME_TEXT_UNREADABLE;
  }
  sep = s[i++];
  if ( ca_time_text_digits(s, n, &i, 1, 2, &mon) == 0 ) {
    return CA_TIME_TEXT_UNREADABLE;
  }
  if ( mon < 1 || mon > 12 ) {
    return CA_TIME_TEXT_UNREADABLE;
  }
  t->months = ( year - 1970 ) * 12 + ( mon - 1 );
  if ( wide && i == n ) {
    t->coarse = 1;
    t->days = ca_time_text_days_from_civil(year, mon, 1);
    t->nsod = 0;
    return CA_TIME_TEXT_OK;
  }
  if ( i >= n || s[i] != sep ) {
    return CA_TIME_TEXT_UNREADABLE;
  }
  i++;
  if ( ca_time_text_digits(s, n, &i, 1, 2, &day) == 0 ) {
    return CA_TIME_TEXT_UNREADABLE;
  }
  if ( day < 1 || day > ca_time_text_month_days(year, mon) ) {
    return CA_TIME_TEXT_UNREADABLE;
  }

  if ( i < n ) {
    if ( s[i] == 'T' ) {
      i++;
    }
    else if ( s[i] == ' ' ) {
      while ( i < n && s[i] == ' ' ) {
        i++;
      }
    }
    else {
      return CA_TIME_TEXT_UNREADABLE;
    }
    if ( ca_time_text_digits(s, n, &i, 1, 2, &hour) == 0 ) {
      return CA_TIME_TEXT_UNREADABLE;
    }
    if ( i >= n || s[i] != ':' ) {
      return CA_TIME_TEXT_UNREADABLE;
    }
    i++;
    if ( ca_time_text_digits(s, n, &i, 2, 2, &min) == 0 ) {
      return CA_TIME_TEXT_UNREADABLE;
    }
    if ( i < n && s[i] == ':' ) {
      i++;
      if ( ca_time_text_digits(s, n, &i, 2, 2, &sec) == 0 ) {
        return CA_TIME_TEXT_UNREADABLE;
      }
      if ( i < n && ( s[i] == '.' || s[i] == ',' ) ) {
        int64_t f;
        int digits;
        i++;
        digits = ca_time_text_digits(s, n, &i, 1, 9, &f);
        if ( digits == 0 ) {
          return CA_TIME_TEXT_UNREADABLE;
        }
        t->fraction = digits;
        frac_ns = f;
        while ( digits++ < 9 ) {
          frac_ns *= 10;
        }
      }
    }
    if ( hour > 23 || min > 59 || sec > 59 ) {
      return CA_TIME_TEXT_UNREADABLE;
    }
    t->clock = 1;

    if ( i < n && s[i] == ' ' ) {
      i++;                          /* one space before a zone */
      if ( i >= n ) {
        return CA_TIME_TEXT_UNREADABLE;
      }
    }
    if ( i < n ) {
      if ( s[i] == 'Z' ) {
        i++;
      }
      else if ( s[i] == '+' || s[i] == '-' ) {
        int negative = ( s[i] == '-' );
        int64_t oh, om = 0, hhmm;
        int digits;
        i++;
        digits = ca_time_text_digits(s, n, &i, 2, 4, &hhmm);
        if ( digits == 4 ) {                  /* +hhmm */
          oh = hhmm / 100;
          om = hhmm % 100;
        }
        else if ( digits == 2 ) {             /* +hh or +hh:mm */
          oh = hhmm;
          if ( i < n && s[i] == ':' ) {
            i++;
            if ( ca_time_text_digits(s, n, &i, 2, 2, &om) == 0 ) {
              return CA_TIME_TEXT_UNREADABLE;
            }
          }
        }
        else {
          return CA_TIME_TEXT_UNREADABLE;
        }
        if ( oh > 23 || om > 59 ) {
          return CA_TIME_TEXT_UNREADABLE;
        }
        offset = ( oh * 3600 + om * 60 ) * ( negative ? -1 : 1 );
      }
      else {
        return CA_TIME_TEXT_UNREADABLE;
      }
    }
  }
  if ( i != n ) {
    return CA_TIME_TEXT_UNREADABLE;
  }

  {
    int64_t nsod = ( hour * 3600 + min * 60 + sec - offset ) * INT64_C(1000000000)
                   + frac_ns;
    int64_t days = ca_time_text_days_from_civil(year, mon, day);
    if ( nsod < 0 ) {
      nsod += ca_ns_per_day;
      days -= 1;
    }
    else if ( nsod >= ca_ns_per_day ) {
      nsod -= ca_ns_per_day;
      days += 1;
    }
    t->days = days;
    t->nsod = nsod;
  }
  return CA_TIME_TEXT_OK;
}

/* Ticks per day and nanoseconds per tick of the units this reader writes. */
static int
ca_time_text_unit (ID unit, int64_t *per_day, int64_t *ns_per_tick)
{
  if ( unit == rb_intern("D") ) {
    *per_day = 1;
    *ns_per_tick = ca_ns_per_day;
  }
  else if ( unit == rb_intern("s") ) {
    *per_day = 86400;
    *ns_per_tick = INT64_C(1000000000);
  }
  else if ( unit == rb_intern("ms") ) {
    *per_day = INT64_C(86400000);
    *ns_per_tick = INT64_C(1000000);
  }
  else if ( unit == rb_intern("us") ) {
    *per_day = INT64_C(86400000000);
    *ns_per_tick = INT64_C(1000);
  }
  else if ( unit == rb_intern("ns") ) {
    *per_day = ca_ns_per_day;
    *ns_per_tick = 1;
  }
  else {
    return 0;
  }
  return 1;
}

/* CArray#__parse_time_text__(unit, report, wide = false)
     -> [int64 ticks, unit] or nil

   Reads an object array of year-first text into tick counts since the
   epoch, wide as the grammar above says when wide is true.  With unit nil
   the unit is the finest the text shows; a unit this reader does not write
   answers nil, and the caller parses another way.
   With an Array as report, the addresses of cells that hold something but
   do not read are pushed onto it; blank, nil and masked cells are missing,
   not unreadable.  A cell that reads but does not fit int64 ticks of the
   unit raises RangeError. */
static VALUE
rb_ca_parse_time_text (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE src = self, out, vdays, vnsod, vmonths, vmask;
  VALUE runit, report, rwide;
  CArray *ca, *co, *cdays, *cnsod, *cmonths, *cmask;
  VALUE *cells;
  boolean8_t *m_in, *m_out;
  int64_t *days, *nsod, *months, *ticks;
  int64_t per_day = 1, ns_per_tick = 1;
  ID unit;
  int clock = 0, fraction = 0, coarse = 2, any = 0, wide;
  int calendar = 0;              /* 1 ticks of months, 2 of years */
  ca_size_t i;

  rb_scan_args(argc, argv, "21", &runit, &report, &rwide);
  wide = RTEST(rwide);

  if ( ! NIL_P(report) ) {
    Check_Type(report, T_ARRAY);
  }
  if ( ! NIL_P(runit) ) {
    unit = SYM2ID(rb_to_symbol(runit));
    if ( ! ca_time_text_unit(unit, &per_day, &ns_per_tick) ) {
      return Qnil;
    }
  }

  TypedData_Get_Struct(src, CArray, &carray_data_type, ca);
  if ( ca->data_type != CA_OBJECT ) {
    rb_raise(rb_eArgError, "time text reading needs an object array");
  }
  if ( ! ca_is_entity(ca) ) {
    src = rb_ca_copy(src);
    TypedData_Get_Struct(src, CArray, &carray_data_type, ca);
  }

  out = rb_carray_new(CA_INT64, ca->ndim, ca->dim, 0, NULL);
  TypedData_Get_Struct(out, CArray, &carray_data_type, co);
  vmask = rb_carray_new(CA_BOOLEAN, ca->ndim, ca->dim, 0, NULL);
  vdays = rb_carray_new(CA_INT64, ca->ndim, ca->dim, 0, NULL);
  TypedData_Get_Struct(vdays, CArray, &carray_data_type, cdays);
  vnsod = rb_carray_new(CA_INT64, ca->ndim, ca->dim, 0, NULL);
  TypedData_Get_Struct(vnsod, CArray, &carray_data_type, cnsod);
  vmonths = rb_carray_new(CA_INT64, ca->ndim, ca->dim, 0, NULL);
  TypedData_Get_Struct(vmonths, CArray, &carray_data_type, cmonths);

  cells = (VALUE *) ca->ptr;
  m_in  = ca_has_mask(ca) ? (boolean8_t *) ca->mask->ptr : NULL;
  TypedData_Get_Struct(vmask, CArray, &carray_data_type, cmask);
  m_out = (boolean8_t *) cmask->ptr;
  days  = (int64_t *) cdays->ptr;
  nsod  = (int64_t *) cnsod->ptr;
  months = (int64_t *) cmonths->ptr;
  ticks = (int64_t *) co->ptr;

  for (i = 0; i < ca->elements; i++) {
    VALUE v = cells[i];
    int rc;
    ca_time_text_t t;
    if ( ( m_in && m_in[i] ) || NIL_P(v) ) {
      rc = CA_TIME_TEXT_BLANK;
    }
    else if ( RB_TYPE_P(v, T_STRING) ) {
      rc = ca_time_text_read(v, &t, wide);
    }
    else {
      rc = CA_TIME_TEXT_UNREADABLE;
    }
    if ( rc == CA_TIME_TEXT_OK ) {
      m_out[i] = 0;
      days[i] = t.days;
      nsod[i] = t.nsod;
      months[i] = t.months;
      clock |= t.clock;
      if ( t.coarse < coarse ) {
        coarse = t.coarse;
      }
      any = 1;
      if ( t.fraction > fraction ) {
        fraction = t.fraction;
      }
    }
    else {
      m_out[i] = 1;
      if ( rc == CA_TIME_TEXT_UNREADABLE && ! NIL_P(report) ) {
        rb_ary_push(report, SIZET2NUM(i));
      }
    }
  }

  if ( NIL_P(runit) ) {
    const char *name = fraction > 6 ? "ns" : fraction > 3 ? "us"
                     : fraction > 0 ? "ms" : clock ? "s" : "D";
    if ( any && ! clock && coarse > 0 ) {
      name = ( coarse == 1 ) ? "M" : "Y";
      calendar = coarse;
    }
    unit = rb_intern(name);
    if ( ! calendar ) {
      ca_time_text_unit(unit, &per_day, &ns_per_tick);
    }
  }

  for (i = 0; i < ca->elements; i++) {
    int64_t whole;
    if ( m_out[i] ) {
      ticks[i] = 0;
      continue;
    }
    if ( calendar ) {
      ticks[i] = ( calendar == 1 ) ? months[i]
                 : ( months[i] >= 0 ? months[i] / 12 : -( ( 11 - months[i] ) / 12 ) );
      continue;
    }
    /* A time that reads but does not fit int64 ticks of the unit is out of
       range, not unreadable, so it raises under every policy rather than
       becoming a masked cell: with the unit chosen from the finest text in
       the column, one cell with nanoseconds would otherwise mask every date
       outside 1677..2262 without a word. */
    if ( __builtin_mul_overflow(days[i], per_day, &whole)
         || __builtin_add_overflow(whole, nsod[i] / ns_per_tick, &ticks[i]) ) {
      rb_raise(rb_eRangeError, "time %" PRIsVALUE " does not fit int64 ticks of %s",
               rb_inspect(cells[i]), rb_id2name(unit));
    }
  }

  ca_mask_from_bytes(co, m_out);
  RB_GC_GUARD(src);
  RB_GC_GUARD(vdays);
  RB_GC_GUARD(vnsod);
  RB_GC_GUARD(vmonths);
  RB_GC_GUARD(vmask);
  return rb_assoc_new(out, ID2SYM(unit));
}

/* Floor division of an int128 by a positive int64. */
static __int128
ca_time_floor_div (__int128 a, int64_t b)
{
  __int128 q = a / b;
  if ( ( a % b ) != 0 && a < 0 ) {
    q -= 1;
  }
  return q;
}

/* CArray.__time_ticks_from_fields__(year, mon, day, sec_of_day, frac_ns,
                                     offset, present, kind, per)
     -> int64 ticks

   Ticks since the epoch from date and time fields already parsed, one
   int64 array per field (offset in seconds east of UTC).  Cells whose
   present byte is 0 come back masked, and so do cells whose tick does not
   fit int64.  kind :fixed counts ticks of `per` nanoseconds; kind
   :calendar counts ticks of `per` months and reads the year and month
   only. */
static VALUE
rb_ca_s_time_ticks_from_fields (VALUE klass,
                                VALUE vyear, VALUE vmon, VALUE vday,
                                VALUE vsod, VALUE vfrac, VALUE voff,
                                VALUE vpresent, VALUE rkind, VALUE rper)
{
  volatile VALUE out, vmask;
  CArray *cy, *cm, *cd, *cs, *cf, *co_, *cp, *co, *cmask;
  int64_t *y, *mo, *d, *sod, *frac, *off, *ticks;
  uint8_t *present;
  boolean8_t *m_out;
  int64_t per = NUM2LL(rper);
  int calendar = ( SYM2ID(rb_to_symbol(rkind)) == rb_intern("calendar") );
  ca_size_t i, n;

  if ( per <= 0 ) {
    rb_raise(rb_eArgError, "tick length must be positive");
  }
#define CA_TIME_FIELD(v, c, field, T)                                  \
  TypedData_Get_Struct(v, CArray, &carray_data_type, c);               \
  if ( ! ca_is_entity(c) ) {                                           \
    rb_raise(rb_eArgError, "time fields must be entities");            \
  }                                                                     \
  field = (T *) c->ptr;
  CA_TIME_FIELD(vyear, cy, y, int64_t);
  CA_TIME_FIELD(vmon, cm, mo, int64_t);
  CA_TIME_FIELD(vday, cd, d, int64_t);
  CA_TIME_FIELD(vsod, cs, sod, int64_t);
  CA_TIME_FIELD(vfrac, cf, frac, int64_t);
  CA_TIME_FIELD(voff, co_, off, int64_t);
  CA_TIME_FIELD(vpresent, cp, present, uint8_t);
#undef CA_TIME_FIELD
  n = cy->elements;
  if ( cy->data_type != CA_INT64 || cm->data_type != CA_INT64
       || cd->data_type != CA_INT64 || cs->data_type != CA_INT64
       || cf->data_type != CA_INT64 || co_->data_type != CA_INT64
       || cp->data_type != CA_UINT8
       || cm->elements != n || cd->elements != n || cs->elements != n
       || cf->elements != n || co_->elements != n || cp->elements != n ) {
    rb_raise(rb_eArgError, "time fields must be int64 arrays of one size "
                           "(present uint8)");
  }

  out = rb_carray_new(CA_INT64, 1, &n, 0, NULL);
  TypedData_Get_Struct(out, CArray, &carray_data_type, co);
  vmask = rb_carray_new(CA_BOOLEAN, 1, &n, 0, NULL);
  ticks = (int64_t *) co->ptr;
  TypedData_Get_Struct(vmask, CArray, &carray_data_type, cmask);
  m_out = (boolean8_t *) cmask->ptr;

  for (i = 0; i < n; i++) {
    __int128 t;
    if ( ! present[i] ) {
      m_out[i] = 1;
      ticks[i] = 0;
      continue;
    }
    if ( calendar ) {
      t = ca_time_floor_div((__int128) ( y[i] - 1970 ) * 12 + ( mo[i] - 1 ), per);
    }
    else {
      __int128 ns = (__int128) ca_time_text_days_from_civil(y[i], mo[i], d[i])
                    * ca_ns_per_day
                    + (__int128) ( sod[i] - off[i] ) * 1000000000
                    + frac[i];
      t = ca_time_floor_div(ns, per);
    }
    if ( t > INT64_MAX || t < INT64_MIN ) {
      m_out[i] = 1;
      ticks[i] = 0;
    }
    else {
      m_out[i] = 0;
      ticks[i] = (int64_t) t;
    }
  }
  ca_mask_from_bytes(co, m_out);
  RB_GC_GUARD(vmask);
  return out;
}

/* ------------------------------------------------------------------------
   Reading text in a strptime format

   This reads the directives Date._strptime reads for a date and a time of
   day, the same way, so that a format answers the same in either: %Y %y %m
   %d %e %H %k %I %l %M %S %N %L %p %P %b %B %h %a %A %z %Z %n %t %%, and
   %D %F %R %T %X %x, which stand for longer formats.  A format with any
   other directive is not read here (the caller uses Date._strptime).
   Text left over after the format makes a cell unreadable, unless it is
   whitespace.  A zone this reader does not know the offset of (a name
   other than Z, UTC and GMT, an offset written another way) is deferred to
   Date._strptime for that cell.

   Strict reading, used to find the format a column is written in, holds
   the text to the shape of the format: %Y is four digits and %y two, %N
   one to nine digits, the other numbers one or two digits (two when a
   number follows directly), no sign and no leading space before a number,
   %p takes AM or PM only, an unknown zone is unreadable rather than
   deferred, and blank text is missing.  Whitespace in the format matches
   any run of whitespace, none included, in both readings.
   ------------------------------------------------------------------------ */

enum {
  CA_STRP_OK = 0,
  CA_STRP_FAIL,
  CA_STRP_DEFER
};

typedef struct {
  int64_t year, mon, mday, hour, min, sec, frac_ns, offset;
  int has_year, has_hour, merid, frac_digits;
} ca_strp_t;

static const char *ca_strp_months[] = {
  "January", "February", "March", "April", "May", "June", "July",
  "August", "September", "October", "November", "December"
};
static const char *ca_strp_days[] = {
  "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday",
  "Saturday"
};

/* Whether a number follows directly: a digit, or a numeric directive. */
static int
ca_strp_number_next (const char *f, long flen, long fi)
{
  char c;
  if ( fi >= flen ) {
    return 0;
  }
  c = f[fi];
  if ( c >= '0' && c <= '9' ) {
    return 1;
  }
  if ( c == '%' && fi + 1 < flen ) {
    c = f[fi + 1];
    if ( c == 'E' || c == 'O' ) {
      c = ( fi + 2 < flen ) ? f[fi + 2] : '\0';
    }
    return c != '\0' && ( strchr("CDdeFGgHIjkLlMmNQRrSsTUuVvWwXxYy", c) != NULL
                          || ( c >= '0' && c <= '9' ) );
  }
  return 0;
}

/* Up to `width` digits (width 0: as many as there are).  Returns the count
   read, with the value of the first 18 in *v. */
static long
ca_strp_digits (const char *s, long n, long *si, long width, int64_t *v)
{
  long count = 0;
  *v = 0;
  while ( *si < n && s[*si] >= '0' && s[*si] <= '9'
          && ( width == 0 || count < width ) ) {
    if ( count < 18 ) {
      *v = *v * 10 + ( s[*si] - '0' );
    }
    (*si)++;
    count++;
  }
  return count;
}

/* A one-or-two-digit field: %d %e %H %k %I %l %M %m %S. */
static int
ca_strp_small (const char *s, long n, long *si, int space_form, int strict,
               int number_next, int64_t lo, int64_t hi, int64_t *v)
{
  long count;
  if ( space_form && ! strict && s[*si] == ' ' ) {
    (*si)++;
    count = ca_strp_digits(s, n, si, 1, v);
  }
  else {
    count = ca_strp_digits(s, n, si, 2, v);
    if ( strict && number_next && count != 2 ) {
      return CA_STRP_FAIL;
    }
  }
  if ( count == 0 || *v < lo || *v > hi ) {
    return CA_STRP_FAIL;
  }
  return CA_STRP_OK;
}

static int
ca_strp_name (const char *s, long n, long *si, const char **names, int count)
{
  int i;
  for (i = 0; i < count; i++) {
    long len = (long) strlen(names[i]);
    if ( n - *si >= len && strncasecmp(names[i], s + *si, len) == 0 ) {
      *si += len;
      return i;
    }
    if ( n - *si >= 3 && strncasecmp(names[i], s + *si, 3) == 0 ) {
      *si += 3;
      return i;
    }
  }
  return -1;
}

static int
ca_strp_is_alpha (char c)
{
  return ( c >= 'A' && c <= 'Z' ) || ( c >= 'a' && c <= 'z' );
}

/* %z: [+-]hh, [+-]hhmm, [+-]hh:mm, Z, UTC, GMT. */
static int
ca_strp_zone (const char *s, long n, long *si, int strict, int64_t *offset)
{
  int unknown = strict ? CA_STRP_FAIL : CA_STRP_DEFER;
  long i = *si;
  if ( s[i] == '+' || s[i] == '-' ) {
    int negative = ( s[i] == '-' );
    int64_t hh, mm = 0;
    long count;
    i++;
    count = ca_strp_digits(s, n, &i, 0, &hh);
    if ( count == 4 ) {
      mm = hh % 100;
      hh = hh / 100;
    }
    else if ( count == 2 ) {
      if ( i < n && s[i] == ':' ) {
        i++;
        if ( ca_strp_digits(s, n, &i, 0, &mm) != 2 ) {
          return unknown;
        }
      }
    }
    else {
      return unknown;
    }
    if ( i < n && ( s[i] == ':' || s[i] == '.' || s[i] == ','
                    || ( s[i] >= '0' && s[i] <= '9' ) ) ) {
      return unknown;
    }
    if ( hh > 23 || mm > 59 ) {
      return unknown;
    }
    *offset = ( hh * 3600 + mm * 60 ) * ( negative ? -1 : 1 );
    *si = i;
    return CA_STRP_OK;
  }
  if ( ca_strp_is_alpha(s[i]) ) {
    long len = 0;
    while ( i + len < n && ca_strp_is_alpha(s[i + len]) ) {
      len++;
    }
    if ( ( len == 1 && s[i] == 'Z' )
         || ( len == 3 && ( strncmp(s + i, "UTC", 3) == 0
                            || strncmp(s + i, "GMT", 3) == 0 ) ) ) {
      long j = i + len;
      /* "UTC+09:00", "GMT standard time", "UTC dst" mean something else */
      if ( j < n && ( s[j] == '+' || s[j] == '-' || s[j] == '.' ) ) {
        return unknown;
      }
      if ( j < n && s[j] == ' ' ) {
        long k = j;
        while ( k < n && s[k] == ' ' ) {
          k++;
        }
        if ( k < n && ca_strp_is_alpha(s[k]) ) {
          return unknown;
        }
      }
      *offset = 0;
      *si = j;
      return CA_STRP_OK;
    }
    return unknown;
  }
  return CA_STRP_FAIL;
}

static int ca_strp_run (const char *s, long n, long *si,
                        const char *f, long flen, int strict, ca_strp_t *t);

static int
ca_strp_sub (const char *s, long n, long *si, const char *sub, int strict,
             ca_strp_t *t)
{
  return ca_strp_run(s, n, si, sub, (long) strlen(sub), strict, t);
}

static int
ca_strp_run (const char *s, long n, long *si, const char *f, long flen,
             int strict, ca_strp_t *t)
{
  long fi = 0;
  while ( fi < flen ) {
    char c = f[fi];
    if ( ca_time_text_is_space(c) ) {
      while ( *si < n && ca_time_text_is_space(s[*si]) ) {
        (*si)++;
      }
      while ( fi < flen && ca_time_text_is_space(f[fi]) ) {
        fi++;
      }
      continue;
    }
    if ( *si >= n ) {
      return CA_STRP_FAIL;
    }
    if ( c != '%' ) {
      if ( s[*si] != c ) {
        return CA_STRP_FAIL;
      }
      (*si)++;
      fi++;
      continue;
    }
    {
      int rc = CA_STRP_OK;
      int number_next;
      int64_t v;
      char d = ( fi + 1 < flen ) ? f[fi + 1] : '\0';
      fi += 2;
      number_next = ca_strp_number_next(f, flen, fi);
      switch ( d ) {
      case 'a': case 'A':
        if ( ca_strp_name(s, n, si, ca_strp_days, 7) < 0 ) {
          return CA_STRP_FAIL;
        }
        break;
      case 'b': case 'B': case 'h': {
        int m = ca_strp_name(s, n, si, ca_strp_months, 12);
        if ( m < 0 ) {
          return CA_STRP_FAIL;
        }
        t->mon = m + 1;
        break;
      }
      case 'd': case 'e':
        rc = ca_strp_small(s, n, si, 1, strict, number_next, 1, 31, &t->mday);
        break;
      case 'H': case 'k':
        rc = ca_strp_small(s, n, si, 1, strict, number_next, 0, 24, &t->hour);
        t->has_hour = 1;
        break;
      case 'I': case 'l':
        rc = ca_strp_small(s, n, si, 1, strict, number_next, 1, 12, &t->hour);
        t->has_hour = 1;
        break;
      case 'M':
        rc = ca_strp_small(s, n, si, 0, strict, number_next, 0, 59, &t->min);
        break;
      case 'm':
        rc = ca_strp_small(s, n, si, 0, strict, number_next, 1, 12, &t->mon);
        break;
      case 'S':
        rc = ca_strp_small(s, n, si, 0, strict, number_next, 0, 60, &t->sec);
        break;
      case 'L': case 'N': {
        int negative = 0;
        long count, start, k;
        int64_t ns = 0;
        int rest = 0;
        if ( ! strict && ( s[*si] == '+' || s[*si] == '-' ) ) {
          negative = ( s[*si] == '-' );
          (*si)++;
        }
        start = *si;
        count = ca_strp_digits(s, n, si,
                               strict ? 9 : ( number_next ? ( d == 'L' ? 3 : 9 ) : 0 ),
                               &v);
        if ( count == 0 ) {
          return CA_STRP_FAIL;
        }
        for (k = 0; k < 9; k++) {
          ns = ns * 10 + ( k < count ? s[start + k] - '0' : 0 );
        }
        for (k = 9; k < count; k++) {
          rest |= ( s[start + k] != '0' );
        }
        if ( negative ) {
          ns = - ns - ( rest ? 1 : 0 );     /* floor, as (fraction * 1e9).floor */
        }
        t->frac_ns = ns;
        t->frac_digits = (int) count;
        break;
      }
      case 'p': case 'P': {
        char a, m;
        int hour;
        if ( n - *si < 2 ) {
          return CA_STRP_FAIL;
        }
        a = s[*si];
        hour = ( a == 'P' || a == 'p' ) ? 12 : 0;
        if ( ! hour && ! ( a == 'A' || a == 'a' ) ) {
          return CA_STRP_FAIL;
        }
        m = s[*si + 1];
        if ( m == '.' && ! strict ) {
          if ( n - *si < 4 || s[*si + 3] != '.' ) {
            return CA_STRP_FAIL;
          }
          *si += 2;
          m = s[*si];
        }
        if ( ! ( m == 'M' || m == 'm' ) ) {
          return CA_STRP_FAIL;
        }
        *si += 2;
        t->merid = hour;
        break;
      }
      case 'Y': {
        int negative = 0;
        long count;
        if ( ! strict && ( s[*si] == '+' || s[*si] == '-' ) ) {
          negative = ( s[*si] == '-' );
          (*si)++;
        }
        count = ca_strp_digits(s, n, si, ( strict || number_next ) ? 4 : 0, &v);
        if ( count == 0 || ( strict && count != 4 ) ) {
          return CA_STRP_FAIL;
        }
        if ( count > 9 ) {
          return CA_STRP_DEFER;            /* a year past int64 days */
        }
        t->year = negative ? -v : v;
        t->has_year = 1;
        break;
      }
      case 'y': {
        long count = ca_strp_digits(s, n, si, 2, &v);
        if ( count == 0 || ( strict && count != 2 ) ) {
          return CA_STRP_FAIL;
        }
        t->year = v + ( v >= 69 ? 1900 : 2000 );
        t->has_year = 1;
        break;
      }
      case 'z': case 'Z':
        rc = ca_strp_zone(s, n, si, strict, &t->offset);
        break;
      case 'n': case 't':
        rc = ca_strp_sub(s, n, si, " ", strict, t);
        break;
      case 'D': case 'x':
        rc = ca_strp_sub(s, n, si, "%m/%d/%y", strict, t);
        break;
      case 'F':
        rc = ca_strp_sub(s, n, si, "%Y-%m-%d", strict, t);
        break;
      case 'R':
        rc = ca_strp_sub(s, n, si, "%H:%M", strict, t);
        break;
      case 'T': case 'X':
        rc = ca_strp_sub(s, n, si, "%H:%M:%S", strict, t);
        break;
      case '%':
        if ( s[*si] != '%' ) {
          return CA_STRP_FAIL;
        }
        (*si)++;
        break;
      default:
        return CA_STRP_FAIL;                /* not reached: checked up front */
      }
      if ( rc != CA_STRP_OK ) {
        return rc;
      }
    }
  }
  return CA_STRP_OK;
}

/* Whether every directive of the format is one ca_strp_run reads. */
static int
ca_strp_supported (const char *f, long flen)
{
  long i;
  for (i = 0; i < flen; i++) {
    if ( f[i] == '%' ) {
      char d = ( i + 1 < flen ) ? f[i + 1] : '\0';
      if ( d == '\0' || strchr("YymdeHkIlMSNLpPbBhaAzZntDFRTXx%", d) == NULL ) {
        return 0;
      }
      i++;
    }
  }
  return 1;
}

/* One text in a format: CA_STRP_OK with the fields in *t, CA_STRP_FAIL,
   or CA_STRP_DEFER. */
static int
ca_strp_text (VALUE str, const char *f, long flen, int strict, ca_strp_t *t)
{
  const char *s = RSTRING_PTR(str);
  long n = RSTRING_LEN(str);
  long si = 0;
  int rc;
  memset(t, 0, sizeof(*t));
  t->mon = 1;
  t->mday = 1;
  t->merid = -1;
  rc = ca_strp_run(s, n, &si, f, flen, strict, t);
  if ( rc != CA_STRP_OK ) {
    return rc;
  }
  while ( si < n && ca_time_text_is_space(s[si]) ) {
    si++;
  }
  if ( si < n || ! t->has_year ) {
    return CA_STRP_FAIL;
  }
  if ( t->merid >= 0 && t->has_hour ) {
    t->hour = t->hour % 12 + t->merid;
  }
  /* Hour 24 is the end of the day, 24:00:00, and nothing past it: 24:30
     would otherwise roll into the next day. */
  if ( t->hour == 24 && ( t->min || t->sec || t->frac_ns ) ) {
    return CA_STRP_FAIL;
  }
  if ( t->mday > ca_time_text_month_days(t->year, t->mon) ) {
    return CA_STRP_FAIL;
  }
  return CA_STRP_OK;
}

/* CArray#__strptime_fields__(format, strict)
     -> [year, mon, day, sec_of_day, frac_ns, offset, present,
         unreadable, deferred, fraction_digits] or nil

   Reads every cell of an object array in a strptime format into the int64
   field arrays CArray.__time_ticks_from_fields__ takes (present is uint8).
   nil when the format has a directive this reader does not read.  A cell
   that holds text and does not read is listed by its address in
   `unreadable`; a cell that is not a String, or holds a zone or a year
   this reader leaves to Date._strptime, in `deferred`; nil and masked
   cells in neither, and blank text too when strict (a blank cell does not
   read in a format, as Date._strptime has it).  fraction_digits is the widest fraction of a
   second read. */
static VALUE
rb_ca_strptime_fields (VALUE self, VALUE rformat, VALUE rstrict)
{
  volatile VALUE src = self, rf = rformat;
  VALUE fields[7];
  volatile VALUE unreadable, deferred;
  CArray *ca, *cf[7];
  int64_t *y, *mo, *d, *sod, *frac, *off;
  uint8_t *present;
  VALUE *cells;
  boolean8_t *m_in;
  const char *f;
  long flen;
  int strict = RTEST(rstrict);
  int fraction = 0;
  ca_size_t i;
  int k;

  StringValue(rf);
  f = RSTRING_PTR(rf);
  flen = RSTRING_LEN(rf);
  if ( ! ca_strp_supported(f, flen) ) {
    return Qnil;
  }
  TypedData_Get_Struct(src, CArray, &carray_data_type, ca);
  if ( ca->data_type != CA_OBJECT ) {
    rb_raise(rb_eArgError, "strptime reading needs an object array");
  }
  if ( ! ca_is_entity(ca) ) {
    src = rb_ca_copy(src);
    TypedData_Get_Struct(src, CArray, &carray_data_type, ca);
  }
  for (k = 0; k < 7; k++) {
    fields[k] = rb_carray_new(k == 6 ? CA_UINT8 : CA_INT64, 1, &ca->elements, 0, NULL);
    TypedData_Get_Struct(fields[k], CArray, &carray_data_type, cf[k]);
  }
  y = (int64_t *) cf[0]->ptr;
  mo = (int64_t *) cf[1]->ptr;
  d = (int64_t *) cf[2]->ptr;
  sod = (int64_t *) cf[3]->ptr;
  frac = (int64_t *) cf[4]->ptr;
  off = (int64_t *) cf[5]->ptr;
  present = (uint8_t *) cf[6]->ptr;
  unreadable = rb_ary_new();
  deferred = rb_ary_new();

  cells = (VALUE *) ca->ptr;
  m_in = ca_has_mask(ca) ? (boolean8_t *) ca->mask->ptr : NULL;
  for (i = 0; i < ca->elements; i++) {
    VALUE v = cells[i];
    ca_strp_t t;
    int rc;
    y[i] = 1970; mo[i] = 1; d[i] = 1; sod[i] = 0; frac[i] = 0; off[i] = 0;
    present[i] = 0;
    if ( ( m_in && m_in[i] ) || NIL_P(v) ) {
      continue;
    }
    if ( ! RB_TYPE_P(v, T_STRING) ) {
      rb_ary_push(deferred, SIZET2NUM(i));
      continue;
    }
    if ( strict ) {                        /* finding a format: blank is missing */
      const char *s = RSTRING_PTR(v);
      long n = RSTRING_LEN(v), j = 0;
      while ( j < n && ca_time_text_is_space(s[j]) ) {
        j++;
      }
      if ( j == n ) {
        continue;
      }
    }
    rc = ca_strp_text(v, f, flen, strict, &t);
    if ( rc == CA_STRP_OK ) {
      y[i] = t.year;
      mo[i] = t.mon;
      d[i] = t.mday;
      sod[i] = t.hour * 3600 + t.min * 60 + t.sec;
      frac[i] = t.frac_ns;
      off[i] = t.offset;
      present[i] = 1;
      if ( t.frac_digits > fraction ) {
        fraction = t.frac_digits;
      }
    }
    else if ( rc == CA_STRP_DEFER ) {
      rb_ary_push(deferred, SIZET2NUM(i));
    }
    else {
      rb_ary_push(unreadable, SIZET2NUM(i));
    }
  }
  RB_GC_GUARD(src);
  RB_GC_GUARD(rf);
  return rb_ary_new_from_args(10, fields[0], fields[1], fields[2], fields[3],
                              fields[4], fields[5], fields[6],
                              unreadable, deferred, INT2NUM(fraction));
}

/* CArray.__strptime_fits__(text, formats) -> indices

   The indices of the formats `text` reads in, strictly. */
static VALUE
rb_ca_s_strptime_fits (VALUE klass, VALUE text, VALUE formats)
{
  volatile VALUE out = rb_ary_new();
  long i;
  StringValue(text);
  Check_Type(formats, T_ARRAY);
  for (i = 0; i < RARRAY_LEN(formats); i++) {
    VALUE f = rb_ary_entry(formats, i);
    ca_strp_t t;
    StringValue(f);
    if ( ca_strp_supported(RSTRING_PTR(f), RSTRING_LEN(f))
         && ca_strp_text(text, RSTRING_PTR(f), RSTRING_LEN(f), 1, &t) == CA_STRP_OK ) {
      rb_ary_push(out, LONG2NUM(i));
    }
  }
  return out;
}

void
Init_carray_time_text (void)
{
  /* Internal: CAFrame reads text columns as time with this reader. */
  rb_define_method(rb_cCArray, "__parse_time_text__", rb_ca_parse_time_text, -1);
  /* Internal: CArray.time turns parsed fields into ticks with this. */
  rb_define_singleton_method(rb_cCArray, "__time_ticks_from_fields__",
                             rb_ca_s_time_ticks_from_fields, 9);
  /* Internal: CArray.time and CAFrame read a strptime format with these. */
  rb_define_method(rb_cCArray, "__strptime_fields__", rb_ca_strptime_fields, 2);
  rb_define_singleton_method(rb_cCArray, "__strptime_fits__",
                             rb_ca_s_strptime_fits, 2);
}
