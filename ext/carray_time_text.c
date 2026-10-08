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

   The unit of the result is the finest the text shows, unless one is
   given: :D when no cell has a time of day, :s with one, and :ms / :us /
   :ns when a fraction of a second has up to 3 / 6 / 9 digits.
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
ca_time_text_read (VALUE str, ca_time_text_t *t)
{
  const char *s = RSTRING_PTR(str);
  long n = RSTRING_LEN(str);
  long i = 0;
  int64_t year, mon, day, hour = 0, min = 0, sec = 0, frac_ns = 0;
  int64_t offset = 0;
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

  if ( ca_time_text_digits(s, n, &i, 4, 4, &year) == 0 ) {
    return CA_TIME_TEXT_UNREADABLE;
  }
  if ( i >= n || ( s[i] != '-' && s[i] != '/' ) ) {
    return CA_TIME_TEXT_UNREADABLE;
  }
  sep = s[i++];
  if ( ca_time_text_digits(s, n, &i, 1, 2, &mon) == 0 ) {
    return CA_TIME_TEXT_UNREADABLE;
  }
  if ( i >= n || s[i] != sep ) {
    return CA_TIME_TEXT_UNREADABLE;
  }
  i++;
  if ( ca_time_text_digits(s, n, &i, 1, 2, &day) == 0 ) {
    return CA_TIME_TEXT_UNREADABLE;
  }
  if ( mon < 1 || mon > 12 || day < 1
       || day > ca_time_text_month_days(year, mon) ) {
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

/* CArray#__parse_time_text__(unit, report) -> [int64 ticks, unit] or nil

   Reads an object array of year-first text into tick counts since the
   epoch.  With unit nil the unit is the finest the text shows; a unit this
   reader does not write answers nil, and the caller parses another way.
   With an Array as report, the addresses of cells that hold something but
   do not read (or do not fit int64 in the unit) are pushed onto it; blank,
   nil and masked cells are missing, not unreadable. */
static VALUE
rb_ca_parse_time_text (VALUE self, VALUE runit, VALUE report)
{
  volatile VALUE src = self, out, vdays, vnsod, vmask;
  CArray *ca, *co, *cdays, *cnsod, *cmask;
  VALUE *cells;
  boolean8_t *m_in, *m_out;
  int64_t *days, *nsod, *ticks;
  int64_t per_day, ns_per_tick;
  ID unit;
  int clock = 0, fraction = 0;
  ca_size_t i;

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

  cells = (VALUE *) ca->ptr;
  m_in  = ca_has_mask(ca) ? (boolean8_t *) ca->mask->ptr : NULL;
  TypedData_Get_Struct(vmask, CArray, &carray_data_type, cmask);
  m_out = (boolean8_t *) cmask->ptr;
  days  = (int64_t *) cdays->ptr;
  nsod  = (int64_t *) cnsod->ptr;
  ticks = (int64_t *) co->ptr;

  for (i = 0; i < ca->elements; i++) {
    VALUE v = cells[i];
    int rc;
    ca_time_text_t t;
    if ( ( m_in && m_in[i] ) || NIL_P(v) ) {
      rc = CA_TIME_TEXT_BLANK;
    }
    else if ( RB_TYPE_P(v, T_STRING) ) {
      rc = ca_time_text_read(v, &t);
    }
    else {
      rc = CA_TIME_TEXT_UNREADABLE;
    }
    if ( rc == CA_TIME_TEXT_OK ) {
      m_out[i] = 0;
      days[i] = t.days;
      nsod[i] = t.nsod;
      clock |= t.clock;
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
    unit = rb_intern(name);
    ca_time_text_unit(unit, &per_day, &ns_per_tick);
  }

  for (i = 0; i < ca->elements; i++) {
    int64_t whole;
    if ( m_out[i] ) {
      ticks[i] = 0;
      continue;
    }
    if ( __builtin_mul_overflow(days[i], per_day, &whole)
         || __builtin_add_overflow(whole, nsod[i] / ns_per_tick, &ticks[i]) ) {
      m_out[i] = 1;
      ticks[i] = 0;
      if ( ! NIL_P(report) ) {
        rb_ary_push(report, SIZET2NUM(i));
      }
    }
  }

  ca_mask_from_bytes(co, m_out);
  RB_GC_GUARD(src);
  RB_GC_GUARD(vdays);
  RB_GC_GUARD(vnsod);
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

void
Init_carray_time_text (void)
{
  /* Internal: CAFrame reads text columns as time with this reader. */
  rb_define_method(rb_cCArray, "__parse_time_text__", rb_ca_parse_time_text, 2);
  /* Internal: CArray.time turns parsed fields into ticks with this. */
  rb_define_singleton_method(rb_cCArray, "__time_ticks_from_fields__",
                             rb_ca_s_time_ticks_from_fields, 9);
}
