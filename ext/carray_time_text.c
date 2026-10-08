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
  volatile VALUE src = self, out, vdays, vnsod;
  CArray *ca, *co, *cdays, *cnsod;
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
  ca_create_mask(co);
  vdays = rb_carray_new(CA_INT64, ca->ndim, ca->dim, 0, NULL);
  TypedData_Get_Struct(vdays, CArray, &carray_data_type, cdays);
  vnsod = rb_carray_new(CA_INT64, ca->ndim, ca->dim, 0, NULL);
  TypedData_Get_Struct(vnsod, CArray, &carray_data_type, cnsod);

  cells = (VALUE *) ca->ptr;
  m_in  = ca_has_mask(ca) ? (boolean8_t *) ca->mask->ptr : NULL;
  m_out = (boolean8_t *) co->mask->ptr;
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

  RB_GC_GUARD(src);
  RB_GC_GUARD(vdays);
  RB_GC_GUARD(vnsod);
  return rb_assoc_new(out, ID2SYM(unit));
}

void
Init_carray_time_text (void)
{
  /* Internal: CAFrame reads text columns as time with this reader. */
  rb_define_method(rb_cCArray, "__parse_time_text__", rb_ca_parse_time_text, 2);
}
