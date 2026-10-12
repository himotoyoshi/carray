/* CSV body reader for CAFrame.from_csv.

   CArray.__csv_read_body_as_string_cells__(text, sep, quote, ncol, keep)
     -> [ncol, cells, records]
   reads every record of text into one flat Array of nrow * ncol cells, row
   after row: a String for a field, UNDEF for a missing one (an unquoted
   empty field, or a cell a short row never reached).  keep, when not nil,
   is the ascending Array of the indexes of the columns to read: a row then
   has a cell for each of them only, and the fields of the others are passed
   over without being copied out of the text.  records counts the
   records read, blank lines included, as the Ruby tokenizer numbers them.
   With ncol 0 the column count is the first record's, as for a file with no
   header; a later record that is longer is then one this reader declines.

   CArray.__csv_read_body_as_const_string_columns__(text, sep, quote, ncol, keep)
     -> [ncol, buffer, [pairs, ...], records]
   reads the same records into one fixlen-16 (start, end) pair entity per
   column read, the layout CAConstString.wrap takes, with missing cells masked.
   The pairs index buffer, which is text itself when no field held a doubled
   quote, and text followed by those fields' unescaped bytes otherwise, so
   the cells are not copied out of the text.

   Both follow the rules of the Ruby tokenizer in
   lib/carray/frame/csv_parser.rb, which stays the reference: a quoted field
   may hold the separator, doubled quotes and line breaks; a line that is
   empty, or only spaces and tabs with no separator, is not a row unless the
   file has one column.  They answer nil, for the Ruby tokenizer to read the
   text and say what is wrong, when the text is not UTF-8 or US-ASCII or has
   an invalid byte, when a record is malformed or longer than ncol, and when
   keep names no column or one past the last. */

#include "carray.h"
#include "carray_internal.h"
#include "ruby/encoding.h"

static int
ca_csv_at (const char *s, long n, long p, const char *t, long tlen)
{
  return p + tlen <= n && memcmp(s + p, t, tlen) == 0;
}

/* The end of the line content that starts at p: the position of its "\n",
   or n; *next is where the following line starts.  A "\r" before the "\n",
   or at the end of the text, is not content. */
static long
ca_csv_line_end (const char *s, long n, long p, long *next)
{
  const char *nl = memchr(s + p, '\n', n - p);
  long e = nl ? nl - s : n;
  *next = nl ? e + 1 : n;
  if ( e > p && s[e - 1] == '\r' ) {
    e -= 1;
  }
  return e;
}

/* A growing list of (start, end) pairs.  A pair at or past the length of
   the text indexes the unescaped tail; a missing cell is (-1, -1). */
typedef struct {
  int64_t *v;
  long len, cap;           /* in pairs */
} ca_csv_cell_ranges;

static void
ca_csv_push_cell_range (ca_csv_cell_ranges *a, int64_t start, int64_t end)
{
  if ( a->len == a->cap ) {
    a->cap = a->cap ? 2 * a->cap : 4096;
    REALLOC_N(a->v, int64_t, 2 * a->cap);
  }
  a->v[2 * a->len]     = start;
  a->v[2 * a->len + 1] = end;
  a->len++;
}

typedef struct {
  ca_csv_cell_ranges cells;      /* row after row */
  ca_csv_cell_ranges pending;    /* blank lines before the first record */
  VALUE tail;              /* unescaped quoted fields, or Qnil */
  VALUE keep;              /* the indexes of the columns to read, or Qnil */
  char *kept;              /* keep as a byte per column, 1 for one read;
                              NULL for every column, or before ncol is known */
  long ncol;
  long width;              /* the cells of a row: those of the columns read */
  long records;
} ca_csv_walk_t;

/* Set w->kept and w->width from w->keep for w->ncol columns.  Returns 0 when
   keep names no column or one past the last. */
static int
ca_csv_set_kept_columns (ca_csv_walk_t *w)
{
  long i;
  w->kept = ALLOC_N(char, w->ncol);
  memset(w->kept, 0, w->ncol);
  for (i = 0; i < RARRAY_LEN(w->keep); i++) {
    long j = NUM2LONG(rb_ary_entry(w->keep, i));
    if ( j < 0 || j >= w->ncol ) {
      return 0;
    }
    if ( ! w->kept[j] ) {
      w->kept[j] = 1;
      w->width++;
    }
  }
  return w->width > 0;
}

/* Read every record of s into w.  Returns 0 when the text is one this
   reader declines (see the header comment).  The cell ranges it grows are
   the caller's to free, whether it returns or raises. */
static int
ca_csv_walk_records (const char *s, long n, const char *sp, long slen,
             const char *qp, long qlen, ca_csv_walk_t *w)
{
  long ncol = w->ncol, p = 0;

  if ( ! NIL_P(w->keep) && ncol > 0 && ! ca_csv_set_kept_columns(w) ) {
    return 0;
  }
  while ( p < n ) {
    long next, e = ca_csv_line_end(s, n, p, &next), k, fields = 0;
    int blank = 1;

    w->records += 1;

    /* A blank line: empty, or only spaces and tabs with no separator. */
    for (k = p; k < e; k++) {
      if ( s[k] != ' ' && s[k] != '\t' ) {
        blank = 0;
        break;
      }
    }
    if ( blank ) {
      for (k = p; k + slen <= e; k++) {
        if ( memcmp(s + k, sp, slen) == 0 ) {
          blank = 0;
          break;
        }
      }
    }
    if ( blank ) {
      int64_t a = e > p ? p : -1, b = e > p ? e : -1;
      if ( ncol == 1 ) {
        if ( w->kept == NULL || w->kept[0] ) {
          ca_csv_push_cell_range(&w->cells, a, b);
        }
      }
      else if ( ncol == 0 ) {
        /* Before the first record the column count is not known: keep the
           line, a row if that record turns out to have one column. */
        ca_csv_push_cell_range(&w->pending, a, b);
      }
      p = next;
      continue;
    }

    for (;;) {
      int64_t a = -1, b = -1;
      /* The field of a column not read is passed over, its text not
         unescaped. */
      int read = w->kept == NULL || ( fields < ncol && w->kept[fields] );
      if ( ca_csv_at(s, n, p, qp, qlen) ) {
        /* A quoted field, which may run onto later lines. */
        long q = p + qlen, start = q, tail0 = -1;
        for (;;) {
          const char *hit = NULL;
          long r = q;
          while ( r + qlen <= n ) {
            const char *c = memchr(s + r, qp[0], n - r);
            if ( c == NULL ) {
              break;
            }
            r = c - s;
            if ( ca_csv_at(s, n, r, qp, qlen) ) {
              hit = c;
              break;
            }
            r++;
          }
          if ( hit == NULL ) {
            return 0;                           /* unterminated */
          }
          if ( ca_csv_at(s, n, r + qlen, qp, qlen) ) {
            /* a doubled quote is a literal one */
            if ( ! read ) {
              q = r + 2 * qlen;
              continue;
            }
            if ( NIL_P(w->tail) ) {
              w->tail = rb_str_buf_new(256);
            }
            if ( tail0 < 0 ) {
              tail0 = RSTRING_LEN(w->tail);
              rb_str_cat(w->tail, s + start, r + qlen - start);
            }
            else {
              rb_str_cat(w->tail, s + q, r + qlen - q);
            }
            q = r + 2 * qlen;
            continue;
          }
          if ( tail0 < 0 ) {
            a = start;
            b = r;
          }
          else {
            rb_str_cat(w->tail, s + q, r - q);
            a = n + tail0;
            b = n + RSTRING_LEN(w->tail);
          }
          p = r + qlen;
          break;
        }
        e = ca_csv_line_end(s, n, p, &next);
        if ( p != e && ! ca_csv_at(s, n, p, sp, slen) ) {
          return 0;                             /* text after the closing quote */
        }
      }
      else {
        long r = p;
        if ( slen == 1 && qlen == 1 ) {
          const char sc = sp[0], qc = qp[0];
          while ( r < e && s[r] != sc ) {
            if ( s[r] == qc ) {
              return 0;                         /* a quote in an unquoted field */
            }
            r++;
          }
        }
        else {
          while ( r < e && ! ca_csv_at(s, n, r, sp, slen) ) {
            if ( ca_csv_at(s, n, r, qp, qlen) ) {
              return 0;                         /* a quote in an unquoted field */
            }
            r++;
          }
        }
        a = r > p ? p : -1;
        b = r > p ? r : -1;
        p = r;
      }
      if ( ++fields > ncol && ncol > 0 ) {
        return 0;                               /* a row too long */
      }
      if ( read ) {
        ca_csv_push_cell_range(&w->cells, a, b);
      }
      if ( p < e && ca_csv_at(s, n, p, sp, slen) ) {
        p += slen;
        continue;
      }
      break;
    }
    if ( ncol == 0 ) {
      /* The first record sets the column count; the blank lines before it
         are rows of a one-column file and nothing otherwise. */
      ncol = fields;
      if ( ! NIL_P(w->keep) ) {
        /* Its fields were all read, the columns being unknown until now:
           keep those of the columns read. */
        long j, k = 0;
        w->ncol = ncol;
        if ( ! ca_csv_set_kept_columns(w) ) {
          return 0;
        }
        for (j = 0; j < ncol; j++) {
          if ( w->kept[j] ) {
            w->cells.v[2 * k]     = w->cells.v[2 * j];
            w->cells.v[2 * k + 1] = w->cells.v[2 * j + 1];
            k++;
          }
        }
        w->cells.len = k;
      }
      if ( ncol == 1 && w->pending.len > 0 ) {
        long i;
        for (i = 0; i < w->cells.len; i++) {
          ca_csv_push_cell_range(&w->pending, w->cells.v[2 * i], w->cells.v[2 * i + 1]);
        }
        { ca_csv_cell_ranges t = w->cells; w->cells = w->pending; w->pending = t; }
        w->pending.len = 0;
      }
    }
    for (; fields < ncol; fields++) {
      if ( w->kept == NULL || w->kept[fields] ) {
        ca_csv_push_cell_range(&w->cells, -1, -1);
      }
    }
    p = next;
  }
  w->ncol = ncol;
  if ( NIL_P(w->keep) ) {
    w->width = ncol;
  }
  return ncol > 0;                              /* 0: no record */
}

/* The arguments both readers take, checked; 0 for text they decline. */
static int
ca_csv_check_reader_args (VALUE text, VALUE vsep, VALUE vquote, VALUE vncol,
                          VALUE keep, long *ncol)
{
  rb_encoding *enc;
  Check_Type(text, T_STRING);
  Check_Type(vsep, T_STRING);
  Check_Type(vquote, T_STRING);
  if ( ! NIL_P(keep) ) {
    Check_Type(keep, T_ARRAY);
  }
  *ncol = NUM2LONG(vncol);
  enc = rb_enc_get(text);
  if ( ( enc != rb_utf8_encoding() && enc != rb_usascii_encoding() )
       || rb_enc_str_coderange(text) == ENC_CODERANGE_BROKEN || *ncol < 0 ) {
    return 0;
  }
  return RSTRING_LEN(vsep) >= 1 && RSTRING_LEN(vquote) >= 1;
}

/* What a reader makes of the walked records: the Ruby value it answers. */
typedef VALUE (*ca_csv_build_result) (VALUE text, ca_csv_walk_t *w);

typedef struct {
  VALUE text, vsep, vquote, vncol;
  ca_csv_walk_t w;
  ca_csv_build_result build;
} ca_csv_read_body_context;

static VALUE
ca_csv_read_body_walk_and_build (VALUE varg)
{
  ca_csv_read_body_context *c = (ca_csv_read_body_context *) varg;
  if ( ! ca_csv_check_reader_args(c->text, c->vsep, c->vquote, c->vncol, c->w.keep,
                                  &c->w.ncol) ) {
    return Qnil;
  }
  if ( ! ca_csv_walk_records(RSTRING_PTR(c->text), RSTRING_LEN(c->text),
                             RSTRING_PTR(c->vsep), RSTRING_LEN(c->vsep),
                             RSTRING_PTR(c->vquote), RSTRING_LEN(c->vquote), &c->w) ) {
    return Qnil;
  }
  return c->build(c->text, &c->w);
}

static VALUE
ca_csv_read_body_free_cell_ranges (VALUE varg)
{
  ca_csv_read_body_context *c = (ca_csv_read_body_context *) varg;
  xfree(c->w.cells.v);
  xfree(c->w.pending.v);
  xfree(c->w.kept);
  return Qnil;
}

/* Walk the records of text and build the answer from them, with the cell
   ranges freed however that ends: the walk and the build both allocate,
   and so may raise. */
static VALUE
ca_csv_read_body (VALUE text, VALUE vsep, VALUE vquote, VALUE vncol, VALUE keep,
                  ca_csv_build_result build)
{
  ca_csv_read_body_context c = {
    text, vsep, vquote, vncol,
    { { NULL, 0, 0 }, { NULL, 0, 0 }, Qnil, keep, NULL, 0, 0, 0 }, build
  };
  VALUE out = rb_ensure(ca_csv_read_body_walk_and_build, (VALUE) &c,
                        ca_csv_read_body_free_cell_ranges, (VALUE) &c);
  RB_GC_GUARD(c.w.tail);
  return out;
}

static VALUE
ca_csv_build_string_cells (VALUE text, ca_csv_walk_t *w)
{
  volatile VALUE out;
  rb_encoding *enc = rb_enc_get(text);
  const char *s = RSTRING_PTR(text);
  long n = RSTRING_LEN(text), i;

  out = rb_ary_new_capa(w->cells.len);
  for (i = 0; i < w->cells.len; i++) {
    int64_t a = w->cells.v[2 * i], b = w->cells.v[2 * i + 1];
    VALUE cell;
    if ( a < 0 ) {
      cell = CA_UNDEF;
    }
    else if ( a < n ) {
      cell = rb_enc_str_new(s + a, b - a, enc);
    }
    else {
      cell = rb_enc_str_new(RSTRING_PTR(w->tail) + (a - n), b - a, enc);
    }
    rb_ary_push(out, cell);
  }
  return rb_ary_new3(3, LONG2NUM(w->ncol), out, LONG2NUM(w->records));
}

static VALUE
ca_csv_build_const_string_columns (VALUE text, ca_csv_walk_t *w)
{
  volatile VALUE buffer, cols;
  ca_size_t dim[1];
  long nrow, i, j;

  if ( NIL_P(w->tail) ) {
    buffer = text;
  }
  else {
    buffer = rb_str_buf_new(RSTRING_LEN(text) + RSTRING_LEN(w->tail));
    rb_str_cat(buffer, RSTRING_PTR(text), RSTRING_LEN(text));
    rb_str_cat(buffer, RSTRING_PTR(w->tail), RSTRING_LEN(w->tail));
    rb_enc_copy(buffer, text);
  }

  nrow = w->cells.len / w->width;
  dim[0] = (ca_size_t) nrow;
  cols = rb_ary_new_capa(w->width);
  for (j = 0; j < w->width; j++) {
    CArray *pe;
    int64_t *range;
    boolean8_t *m = NULL;
    VALUE col = rb_carray_new(CA_FIXLEN, 1, dim, 2 * sizeof(int64_t), NULL);
    rb_ary_push(cols, col);
    TypedData_Get_Struct(col, CArray, &carray_data_type, pe);
    range = (int64_t *) pe->ptr;
    for (i = 0; i < nrow; i++) {
      int64_t a = w->cells.v[2 * (i * w->width + j)];
      int64_t b = w->cells.v[2 * (i * w->width + j) + 1];
      if ( a < 0 ) {
        if ( m == NULL ) {
          ca_create_mask(pe);
          m = (boolean8_t *) pe->mask->ptr;
        }
        m[i] = 1;
        a = b = 0;
      }
      range[2 * i]     = a;
      range[2 * i + 1] = b;
    }
  }
  return rb_ary_new3(4, LONG2NUM(w->ncol), buffer, cols, LONG2NUM(w->records));
}

static VALUE
rb_ca_s_csv_read_body_as_string_cells (VALUE klass, VALUE text, VALUE vsep, VALUE vquote,
                                       VALUE vncol, VALUE keep)
{
  return ca_csv_read_body(text, vsep, vquote, vncol, keep, ca_csv_build_string_cells);
}

static VALUE
rb_ca_s_csv_read_body_as_const_string_columns (VALUE klass, VALUE text, VALUE vsep, VALUE vquote,
                                               VALUE vncol, VALUE keep)
{
  return ca_csv_read_body(text, vsep, vquote, vncol, keep, ca_csv_build_const_string_columns);
}

void
Init_caframe_csv_reader (void)
{
  rb_define_singleton_method(rb_cCArray, "__csv_read_body_as_string_cells__", rb_ca_s_csv_read_body_as_string_cells, 5);
  rb_define_singleton_method(rb_cCArray, "__csv_read_body_as_const_string_columns__", rb_ca_s_csv_read_body_as_const_string_columns, 5);
}
