/* CSV body reader for CAFrame.from_csv.

   CArray.__csv_split__(text, sep, quote, ncol) -> [ncol, cells, records]
   reads every record of text into one flat Array of nrow * ncol cells, row
   after row: a String for a field, UNDEF for a missing one (an unquoted
   empty field, or a cell a short row never reached).  records counts the
   records read, blank lines included, as the Ruby tokenizer numbers them.
   With ncol 0 the column count is the first record's, as for a file with no
   header; a later record that is longer is then one this reader declines.
   It follows the rules of the Ruby tokenizer in
   lib/carray/frame/csv_parser.rb, which stays the reference: a quoted field
   may hold the separator, doubled quotes and line breaks; a line that is
   empty, or only spaces and tabs with no separator, is not a row unless the
   file has one column.  It answers nil, for the Ruby tokenizer to read the
   text and say what is wrong, when the text is not UTF-8 or US-ASCII or has
   an invalid byte, and when a record is malformed or longer than ncol. */

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

static VALUE
rb_ca_s_csv_split (VALUE klass, VALUE text, VALUE vsep, VALUE vquote, VALUE vncol)
{
  volatile VALUE out, pending = Qnil;
  const char *s, *sp, *qp;
  long n, slen, qlen, ncol, p, records = 0;
  rb_encoding *enc;

  Check_Type(text, T_STRING);
  Check_Type(vsep, T_STRING);
  Check_Type(vquote, T_STRING);
  ncol = NUM2LONG(vncol);
  enc = rb_enc_get(text);
  if ( ( enc != rb_utf8_encoding() && enc != rb_usascii_encoding() )
       || rb_enc_str_coderange(text) == ENC_CODERANGE_BROKEN || ncol < 0 ) {
    return Qnil;
  }
  s = RSTRING_PTR(text);
  n = RSTRING_LEN(text);
  sp = RSTRING_PTR(vsep);
  slen = RSTRING_LEN(vsep);
  qp = RSTRING_PTR(vquote);
  qlen = RSTRING_LEN(vquote);
  if ( slen < 1 || qlen < 1 ) {
    return Qnil;
  }

  out = rb_ary_new_capa(1024);
  p = 0;
  while ( p < n ) {
    long next, e = ca_csv_line_end(s, n, p, &next), k, fields = 0;
    int blank = 1;

    records += 1;

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
      VALUE cell = e > p ? rb_enc_str_new(s + p, e - p, enc) : CA_UNDEF;
      if ( ncol == 1 ) {
        rb_ary_push(out, cell);
      }
      else if ( ncol == 0 ) {
        /* Before the first record the column count is not known: keep the
           line, a row if that record turns out to have one column. */
        if ( NIL_P(pending) ) {
          pending = rb_ary_new();
        }
        rb_ary_push(pending, cell);
      }
      p = next;
      continue;
    }

    for (;;) {
      VALUE cell;
      if ( ca_csv_at(s, n, p, qp, qlen) ) {
        /* A quoted field, which may run onto later lines. */
        long q = p + qlen, start = q;
        VALUE buf = Qnil;
        for (;;) {
          const char *hit = NULL;
          long r;
          for (r = q; r + qlen <= n; r++) {
            if ( memcmp(s + r, qp, qlen) == 0 ) {
              hit = s + r;
              break;
            }
          }
          if ( hit == NULL ) {
            return Qnil;                        /* unterminated */
          }
          if ( ca_csv_at(s, n, r + qlen, qp, qlen) ) {
            /* a doubled quote is a literal one */
            if ( NIL_P(buf) ) {
              buf = rb_enc_str_new(s + start, r + qlen - start, enc);
            }
            else {
              rb_str_cat(buf, s + q, r + qlen - q);
            }
            q = r + 2 * qlen;
            continue;
          }
          if ( NIL_P(buf) ) {
            cell = rb_enc_str_new(s + start, r - start, enc);
          }
          else {
            rb_str_cat(buf, s + q, r - q);
            cell = buf;
          }
          p = r + qlen;
          break;
        }
        e = ca_csv_line_end(s, n, p, &next);
        if ( p != e && ! ca_csv_at(s, n, p, sp, slen) ) {
          return Qnil;                          /* text after the closing quote */
        }
      }
      else {
        long r = p;
        while ( r < e && ! ca_csv_at(s, n, r, sp, slen) ) {
          if ( ca_csv_at(s, n, r, qp, qlen) ) {
            return Qnil;                        /* a quote in an unquoted field */
          }
          r++;
        }
        cell = r > p ? rb_enc_str_new(s + p, r - p, enc) : CA_UNDEF;
        p = r;
      }
      if ( ++fields > ncol && ncol > 0 ) {
        return Qnil;                            /* a row too long */
      }
      rb_ary_push(out, cell);
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
      if ( ncol == 1 && ! NIL_P(pending) ) {
        rb_ary_concat(pending, out);
        out = pending;
      }
    }
    for (; fields < ncol; fields++) {
      rb_ary_push(out, CA_UNDEF);
    }
    p = next;
  }
  if ( ncol == 0 ) {
    return Qnil;                                /* no record */
  }
  return rb_ary_new3(3, LONG2NUM(ncol), out, LONG2NUM(records));
}

void
Init_caframe_csv_split (void)
{
  rb_define_singleton_method(rb_cCArray, "__csv_split__", rb_ca_s_csv_split, 4);
}
