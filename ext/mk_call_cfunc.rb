# ext/mk_call_cfunc.rb -- generator for ext/carray_call_cfunc.{c,h}
#
# Emits the ext-author-facing API `ca_call_cfunc_N` (= raw arity 1..7) and
# `ca_call_cfunc_M_N` (= typed dispatcher) used by external CArray gems
# (carray-gsl, etc.) to wrap C math functions over CArray operations.
#
# Generated 2026-06-10 as part of the PROPOSAL_EAGER_SLOWPATH_CHUNKING_ARENA
# attach-elimination flow extension (= D phase): the raw `ca_call_cfunc_N`
# template applies C.7-style alias / non-alias bifurcation for INPUT-only
# operands (= fsync[k] == '0') and ca_xfer_all-based safe mask gather (= no
# `ca_attach` on operand masks).  OUTPUT operands (= fsync[k] == '1') still
# use ca_attach + ca_sync (= legitimate per the refined input-only-operand
# invariant).
#
# ABI 100% preserved: signatures, data_type semantics, fsync format, return
# behavior all unchanged.  External gems link against the same symbols
# without source change.
#
# Why a generator?  Each of the 7 raw + 13 typed variants is mechanically
# the same body with arity differences.  Hand-keeping 1088 lines invites
# divergence (= the attach-safe rewrite would have to be repeated 20 times
# perfectly).  The generator centralises the template so a single edit
# updates every variant.  Add a new arity / typed pair by appending one
# line to the spec.
#
# Header (`carray_call_cfunc.h`) is emitted alongside the source so the
# extern declarations cannot drift from the function definitions.  Both
# files are written in a single invocation; output paths default to
# `carray_call_cfunc.c` / `carray_call_cfunc.h` in the current directory
# and can be overridden as `ruby mk_call_cfunc.rb <src.c> <hdr.h>`.

# --- spec -------------------------------------------------------------------

RAW_ARITIES = (1..7).to_a          # ca_call_cfunc_1 .. _7
TYPED_PAIRS = [                    # ca_call_cfunc_<m>_<n>  (m outputs, n inputs)
  [1, 1], [1, 2], [1, 3], [1, 4], [1, 5], [1, 6],
  [2, 1], [2, 2], [2, 3], [2, 4],
  [3, 1], [3, 2], [3, 3],
]

# --- helpers ----------------------------------------------------------------

def void_p_list(n)
  (0...n).map { |k| "void *p#{k}" }.join(", ")
end

# For _r variants: callback signature gains a trailing `void *userdata`.
def void_p_list_r(n)
  void_p_list(n) + ", void *userdata"
end

def value_param_list(n, prefix: "rcx")
  (0...n).map { |k| "VALUE #{prefix}#{k}" }.join(", ")
end

def args_p(n)
  (0...n).map { |k| "p[#{k}]" }.join(", ")
end

# For _r variants: inner call gains a trailing `userdata` arg.
def args_p_r(n)
  args_p(n) + ", userdata"
end

# --- signature builders -----------------------------------------------------
#
# Each builder returns the multi-line function prototype (without trailing
# `;` or `{`).  Source emitters append the body; header emitters append `;`.
# Centralising signatures here prevents drift between `.c` and `.h`.

def sig_raw(n)
  "VALUE\nca_call_cfunc_#{n} (void (*func)(#{void_p_list(n)}), const char *fsync,\n                            #{value_param_list(n)})"
end

def sig_raw_r(n)
  "VALUE\nca_call_cfunc_#{n}_r (void (*func)(#{void_p_list_r(n)}), const char *fsync,\n                              #{value_param_list(n)},\n                              void *userdata)"
end

def typed_params(m, n, r: false)
  dty = ->(k) { m == 1 ? "dty"  : "dty#{k + 1}" }
  out_data_type_params = (0...m).map { |k| "int8_t #{dty.(k)}" }
  in_data_type_params  = (0...n).map { |k| "int8_t dtx#{k + 1}" }
  in_value_params      = (0...n).map { |k| "volatile VALUE rx#{k + 1}" }
  fp_args  = ["void*"] * (m + n)
  fp_args << "void *userdata" if r
  func_sig = "void (*mathfunc)(#{fp_args.join(", ")})"
  params = out_data_type_params + in_data_type_params + [func_sig] + in_value_params
  params << "void *userdata" if r
  params.join(", ")
end

def sig_typed(m, n)
  "VALUE\nca_call_cfunc_#{m}_#{n} (#{typed_params(m, n)})"
end

def sig_typed_r(m, n)
  "VALUE\nca_call_cfunc_#{m}_#{n}_r (#{typed_params(m, n, r: true)})"
end

# Re-indent each non-blank line of `s` with `prefix`.  `<<~` strips the
# common leading whitespace from a heredoc, which would leave our body
# at column 0; we want a 2-space body indent inside the function brace.
def indent(s, prefix = "  ")
  s.each_line.map { |l| l.strip.empty? ? l : prefix + l }.join
end

# --- raw ca_call_cfunc_N ----------------------------------------------------

def emit_raw(n)
  $src.puts sig_raw(n)
  $src.puts "{"
  $src.puts indent(<<~END_C)
      CArray   *cx[#{n}];
      char     *base[#{n}];
      ca_size_t stride[#{n}];
      char     *owned_buf[#{n}];
      int       attached[#{n}];
      ca_sweep_state_t state;
      int k_op;

  END_C
  # extract CArray* from VALUE
  (0...n).each do |k|
    $src.puts "  TypedData_Get_Struct(rcx#{k}, CArray, &carray_data_type, cx[#{k}]);"
  end
  $src.puts ""
  $src.puts <<~END_C
      /* sweep engine: per-operand acquire (alias / xmalloc + ca_xfer_all),
         broadcast shape check, mask OR across INPUTs, mask propagate to
         OUTPUTs.  Lifecycle template lives in ext/ca_sweep_engine.{c,h}. */
      state.n_ops     = #{n};
      state.fsync     = fsync;
      state.cx        = cx;
      state.base      = base;
      state.stride    = stride;
      state.owned_buf = owned_buf;
      state.attached  = attached;
      state.no_mask   = 0;
      state.src_label = "ca_call_cfunc_#{n}";

      ca_sweep_acquire(&state);

      /* inner loop: advance per-cell ptrs and invoke user kernel func */
      {
        char *p[#{n}];
        ca_size_t k;
        if ( state.m0 ) {
          for ( k = 0; k < state.n_kernel; k++ ) {
            if ( ! state.m0[k] ) {
              for ( k_op = 0; k_op < #{n}; k_op++ ) {
                p[k_op] = base[k_op] + k * stride[k_op];
              }
              func(#{args_p(n)});
            }
          }
        } else {
          for ( k = 0; k < state.n_kernel; k++ ) {
            for ( k_op = 0; k_op < #{n}; k_op++ ) {
              p[k_op] = base[k_op] + k * stride[k_op];
            }
            func(#{args_p(n)});
          }
        }
      }

      ca_sweep_release(&state);

      return rcx0;
    }

  END_C
end

# --- raw ca_call_cfunc_N_r (reentrant: + void *userdata at signature tail) --
#
# Variant of emit_raw with a trailing `void *userdata` parameter passed
# through to every per-cell `func(...)` invocation as its last argument.
# Naming follows POSIX convention (qsort_r / bsearch_r / strtok_r), where
# `_r` marks a reentrant form that takes a thunk so the callback no longer
# depends on file-static / global state.  Use when the callback needs to
# share state with the caller (e.g. accumulators, configuration flags,
# library plan handles) without resorting to file-static plumbing.
def emit_raw_r(n)
  $src.puts sig_raw_r(n)
  $src.puts "{"
  $src.puts indent(<<~END_C)
      CArray   *cx[#{n}];
      char     *base[#{n}];
      ca_size_t stride[#{n}];
      char     *owned_buf[#{n}];
      int       attached[#{n}];
      ca_sweep_state_t state;
      int k_op;

  END_C
  (0...n).each do |k|
    $src.puts "  TypedData_Get_Struct(rcx#{k}, CArray, &carray_data_type, cx[#{k}]);"
  end
  $src.puts ""
  $src.puts <<~END_C
      /* sweep engine: same lifecycle as ca_call_cfunc_#{n}; the difference is
         the per-cell `func(...)` call has `userdata` as its last argument. */
      state.n_ops     = #{n};
      state.fsync     = fsync;
      state.cx        = cx;
      state.base      = base;
      state.stride    = stride;
      state.owned_buf = owned_buf;
      state.attached  = attached;
      state.no_mask   = 0;
      state.src_label = "ca_call_cfunc_#{n}_r";

      ca_sweep_acquire(&state);

      {
        char *p[#{n}];
        ca_size_t k;
        if ( state.m0 ) {
          for ( k = 0; k < state.n_kernel; k++ ) {
            if ( ! state.m0[k] ) {
              for ( k_op = 0; k_op < #{n}; k_op++ ) {
                p[k_op] = base[k_op] + k * stride[k_op];
              }
              func(#{args_p_r(n)});
            }
          }
        } else {
          for ( k = 0; k < state.n_kernel; k++ ) {
            for ( k_op = 0; k_op < #{n}; k_op++ ) {
              p[k_op] = base[k_op] + k * stride[k_op];
            }
            func(#{args_p_r(n)});
          }
        }
      }

      ca_sweep_release(&state);

      return rcx0;
    }

  END_C
end

# --- typed ca_call_cfunc_M_N ------------------------------------------------

def emit_typed(m, n)
  total = m + n
  # Naming convention (matches legacy ext/carray_call_cfunc.c byte-for-byte):
  #   M==1 : output data_type = `dty`, output var = `ry`
  #   M >1 : output data_types = `dty1..dtyM`, output vars = `ry1..ryM`
  dty = ->(k) { m == 1 ? "dty"  : "dty#{k + 1}" }
  ry  = ->(k) { m == 1 ? "ry"   : "ry#{k + 1}" }

  fsync_str = "1" * m + "0" * n

  $src.puts sig_typed(m, n)
  $src.puts "{"

  # output VALUE declarations
  out_decl = (0...m).map { |k| "#{ry.(k)} = Qnil" }.join(", ")
  $src.puts "  volatile VALUE #{out_decl};"
  $src.puts ""

  # wrap inputs readonly to declared input data_types
  (0...n).each do |k|
    $src.puts "  rx#{k + 1} = rb_ca_wrap_readonly(rx#{k + 1}, INT2NUM(dtx#{k + 1}));"
  end
  $src.puts ""

  # build one output template per output data_type, widening inputs as needed
  (0...m).each do |out_k|
    cur_dty = dty.(out_k)
    conds = (0...n).map { |in_k| "#{cur_dty} != dtx#{in_k + 1}" }
    wrapped = (0...n).map { |in_k|
      "rb_ca_wrap_readonly(rx#{in_k + 1}, INT2NUM(#{cur_dty}))"
    }
    plain = (0...n).map { |in_k| "rx#{in_k + 1}" }
    $src.puts "  if ( #{conds.join(" || ")} ) {"
    $src.puts "    #{ry.(out_k)} = rb_ca_template_n(#{n}, #{wrapped.join(", ")});"
    $src.puts "  } else {"
    $src.puts "    #{ry.(out_k)} = rb_ca_template_n(#{n}, #{plain.join(", ")});"
    $src.puts "  }"
  end
  $src.puts ""

  # delegate to lower-level ca_call_cfunc_(m+n)
  args = (0...m).map { |k| ry.(k) } + (0...n).map { |k| "rx#{k + 1}" }
  $src.puts "  ca_call_cfunc_#{total}(mathfunc, \"#{fsync_str}\", #{args.join(", ")});"
  $src.puts ""

  # return: scalar-fetch each output if rank-0, then assemble
  (0...m).each do |k|
    $src.puts "  if ( rb_ca_is_scalar(#{ry.(k)}) ) {"
    $src.puts "    #{ry.(k)} = rb_ca_fetch_addr(#{ry.(k)}, 0);"
    $src.puts "  }"
  end
  if m == 1
    $src.puts "  return #{ry.(0)};"
  else
    list = (0...m).map { |k| ry.(k) }.join(", ")
    $src.puts "  return rb_ary_new3(#{m}, #{list});"
  end
  $src.puts "}"
  $src.puts ""
end

# --- typed ca_call_cfunc_M_N_r (reentrant variant) -------------------------
#
# Same as emit_typed but the callback signature and outer function gain a
# trailing `void *userdata`; the inner delegate calls ca_call_cfunc_(M+N)_r
# and forwards `userdata` through.
def emit_typed_r(m, n)
  total = m + n
  dty = ->(k) { m == 1 ? "dty"  : "dty#{k + 1}" }
  ry  = ->(k) { m == 1 ? "ry"   : "ry#{k + 1}" }

  fsync_str = "1" * m + "0" * n

  $src.puts sig_typed_r(m, n)
  $src.puts "{"

  out_decl = (0...m).map { |k| "#{ry.(k)} = Qnil" }.join(", ")
  $src.puts "  volatile VALUE #{out_decl};"
  $src.puts ""

  (0...n).each do |k|
    $src.puts "  rx#{k + 1} = rb_ca_wrap_readonly(rx#{k + 1}, INT2NUM(dtx#{k + 1}));"
  end
  $src.puts ""

  (0...m).each do |out_k|
    cur_dty = dty.(out_k)
    conds = (0...n).map { |in_k| "#{cur_dty} != dtx#{in_k + 1}" }
    wrapped = (0...n).map { |in_k|
      "rb_ca_wrap_readonly(rx#{in_k + 1}, INT2NUM(#{cur_dty}))"
    }
    plain = (0...n).map { |in_k| "rx#{in_k + 1}" }
    $src.puts "  if ( #{conds.join(" || ")} ) {"
    $src.puts "    #{ry.(out_k)} = rb_ca_template_n(#{n}, #{wrapped.join(", ")});"
    $src.puts "  } else {"
    $src.puts "    #{ry.(out_k)} = rb_ca_template_n(#{n}, #{plain.join(", ")});"
    $src.puts "  }"
  end
  $src.puts ""

  args = (0...m).map { |k| ry.(k) } + (0...n).map { |k| "rx#{k + 1}" }
  $src.puts "  ca_call_cfunc_#{total}_r(mathfunc, \"#{fsync_str}\", #{args.join(", ")}, userdata);"
  $src.puts ""

  (0...m).each do |k|
    $src.puts "  if ( rb_ca_is_scalar(#{ry.(k)}) ) {"
    $src.puts "    #{ry.(k)} = rb_ca_fetch_addr(#{ry.(k)}, 0);"
    $src.puts "  }"
  end
  if m == 1
    $src.puts "  return #{ry.(0)};"
  else
    list = (0...m).map { |k| ry.(k) }.join(", ")
    $src.puts "  return rb_ary_new3(#{m}, #{list});"
  end
  $src.puts "}"
  $src.puts ""
end

# --- header declaration emitters --------------------------------------------

def decl_raw(n)    ; $hdr.puts sig_raw(n)    + ";"; $hdr.puts ""; end
def decl_raw_r(n)  ; $hdr.puts sig_raw_r(n)  + ";"; $hdr.puts ""; end
def decl_typed(m, n)   ; $hdr.puts sig_typed(m, n)   + ";"; $hdr.puts ""; end
def decl_typed_r(m, n) ; $hdr.puts sig_typed_r(m, n) + ";"; $hdr.puts ""; end

# --- main -------------------------------------------------------------------

src_path = ARGV[0] || "carray_call_cfunc.c"
hdr_path = ARGV[1] || "carray_call_cfunc.h"

$src = File.open(src_path, "w")
$hdr = File.open(hdr_path, "w")

$src.puts <<~END_C
  /* ---------------------------------------------------------------------------
   *
   *  carray_call_cfunc.c -- ext-author math-call wrapper API
   *
   *  GENERATED by ext/mk_call_cfunc.rb -- DO NOT EDIT
   *  To modify the template or add a new arity, edit mk_call_cfunc.rb
   *  and regenerate (= make / extconf re-runs the generator).
   *
   *  Provides `ca_call_cfunc_N` (raw arity 1..7) and `ca_call_cfunc_M_N`
   *  (typed dispatcher) used by external CArray gems (carray-gsl, etc.)
   *  to wrap C math functions over CArray operations.
   *
   *  Reentrant variants `ca_call_cfunc_N_r` and `ca_call_cfunc_M_N_r`
   *  (= POSIX `_r` convention, cf. qsort_r / bsearch_r / strtok_r) take
   *  a trailing `void *userdata` argument that is passed through to every
   *  per-cell callback invocation as its last argument.  Use when the
   *  callback needs to share state with the caller (accumulators,
   *  configuration flags, library plan handles, ...) without resorting to
   *  file-static / global plumbing.
   *
   *  Attach-safe: INPUT-only operands (= fsync[k] == '0') never call
   *  ca_attach on the operand or its mask (= alias check + ALLOCV +
   *  ca_xfer_all for non-alias).  OUTPUT operands (= fsync[k] == '1')
   *  use ca_attach + ca_sync (= legitimate per the refined input-only-
   *  operand invariant established in PROPOSAL_EAGER_ELEMENTWISE_NO_ATTACH
   *  and extended in PROPOSAL_EAGER_SLOWPATH_CHUNKING_ARENA).
   *
   *  L0.1 (PROPOSAL_L0_AUTHOR_SURFACE, 2026-06-11): the per-operand acquire
   *  + broadcast check + mask OR + release lifecycle is now factored out
   *  into ext/ca_sweep_engine.{c,h} (ca_sweep_acquire / ca_sweep_release).  This
   *  file keeps the arity-dependent inner loop only.  ABI unchanged.
   *
   *  --------------------------------------------------------------------------- */

  #include "carray.h"
  #include "ca_sweep_engine.h"
  #include <string.h>

END_C

$hdr.puts <<~END_H
  /* ---------------------------------------------------------------------------
   *
   *  carray_call_cfunc.h -- ext-author math-call wrapper API (declarations)
   *
   *  GENERATED by ext/mk_call_cfunc.rb -- DO NOT EDIT
   *  Edit mk_call_cfunc.rb and rebuild to refresh both this header and
   *  the matching carray_call_cfunc.c.
   *
   *  Included from carray.h so external gems pick up these prototypes
   *  transparently via `#include "carray.h"`.  The generator co-emits
   *  source and header so the prototypes cannot drift from the function
   *  definitions.  See carray_call_cfunc.c for the full design notes.
   *
   *  --------------------------------------------------------------------------- */

  #ifndef CARRAY_CALL_CFUNC_H
  #define CARRAY_CALL_CFUNC_H

END_H

RAW_ARITIES.each do |n|
  emit_raw(n)
  decl_raw(n)
end

$src.puts "/* -------------------------------------------------------------------- */"
$src.puts "/* Typed dispatchers: M outputs, N inputs.  Wrap each input readonly to */"
$src.puts "/* its declared data_type, allocate output template(s), delegate to raw.    */"
$src.puts "/* -------------------------------------------------------------------- */"
$src.puts ""

TYPED_PAIRS.each do |m, n|
  emit_typed(m, n)
  decl_typed(m, n)
end

$src.puts "/* -------------------------------------------------------------------- */"
$src.puts "/* Reentrant variants (`_r` suffix, POSIX convention): same as the    */"
$src.puts "/* corresponding non-`_r` variant but the callback takes a trailing   */"
$src.puts "/* `void *userdata` argument and the outer function takes a trailing  */"
$src.puts "/* `void *userdata` parameter forwarded to every per-cell invocation. */"
$src.puts "/* -------------------------------------------------------------------- */"
$src.puts ""

RAW_ARITIES.each do |n|
  emit_raw_r(n)
  decl_raw_r(n)
end

TYPED_PAIRS.each do |m, n|
  emit_typed_r(m, n)
  decl_typed_r(m, n)
end

$hdr.puts "#endif /* CARRAY_CALL_CFUNC_H */"

$src.close
$hdr.close
