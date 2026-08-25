# Freeze guard for the kernel_iterator AUTHOR surface.
#
# The kernel_iterator surface is split in two (see
# docs/authoring/HOW_TO_WRITE_KERNEL.md §0 and the banner in
# ext/ca_kernel_iterator.h):
#
#   - FROZEN  : the author-facing macros, the raw-API entry points the
#               macros expand to, the enum tokens authors write, and the
#               slab-delivery representation (the `st` fields a kernel
#               reads).  These MUST stay name/arity/semantics-stable from
#               3.0 onward so that ext-gem kernels keep compiling and the
#               engine can be re-implemented behind them (the surface stays fixed).
#   - INTERNAL: everything else (state-machine functions, alias_mode /
#               src_kind enums, scratch / stack / fiber bookkeeping
#               fields).  Free to refactor across 3.x.
#
# This guard fails CI if any FROZEN name disappears from the header
# (= renamed / removed).  It is the mechanical pin behind the prose
# contract: a rename turns the build red instead of silently breaking
# downstream kernels.
#
# It does NOT check arity or semantics — those live in the spec_ai
# kernel tests and the doc.  It only catches the most common drift:
# a frozen identifier vanishing.
#
# Run via: `rake kernel_surface_check` (or directly with
# `ruby devel/check_kernel_surface_freeze.rb`).

HEADER = File.expand_path("../ext/ca_kernel_iterator.h", __dir__)

# --- FROZEN names -----------------------------------------------------------
# Grouped only for readable error output; all are checked the same way.

FROZEN_MACROS = %w[
  CA_FOR_EACH_SLAB
  CA_FOR_EACH_SLAB_INOUT
  CA_FOR_EACH_FIBER
  CA_FOR_EACH_FIBER_MASKED
  CA_FOR_EACH_FIBER_INOUT
  CA_FOR_EACH_FIBER_INOUT_MASKED
  CA_SLAB_REDUCE_T
  CA_SLAB_REDUCE_T_EX
  CA_SLAB_REDUCE_T_PLUS
  CA_SLAB_REDUCE_T_PLUS_EX
  CA_SLAB_REDUCE_T_MIN
  CA_SLAB_REDUCE_T_MIN_EX
  CA_SLAB_REDUCE_T_MAX
  CA_SLAB_REDUCE_T_MAX_EX
  CA_SLAB_REDUCE_T_STAR
  CA_SLAB_REDUCE_T_STAR_EX
  CA_SLAB_REDUCE_F64
  CA_SLAB_REDUCE_F32
  CA_SLAB_REDUCE_I32
  CA_SLAB_REDUCE_I64
  CA_SLAB_REDUCE_ARRAY_T
  CA_SLAB_REDUCE_ARRAY_T_EX
  CA_SLAB_REDUCE_ARRAY_T_PLUS
  CA_SLAB_REDUCE_ARRAY_T_PLUS_EX
  CA_SLAB_MAP_T
  CA_SLAB_MAP_F64
  CA_SLAB_SCAN_T
  CA_SLAB_SCAN_TA
  CA_FOR_EACH_UNMASKED
  CA_FOR_EACH_INDEX_UNMASKED
  CA_COUNT_UNMASKED
  CA_MASK_GET
  CA_L2_FOR_EACH
  CA_L2_FOR_EACH_UNMASKED
]

# Raw-API entry points the macros expand to (also callable directly by
# kernels that need explicit error handling — see doc §6.3).
FROZEN_FUNCS = %w[
  ca_iter_state_init_l2
  ca_iter_state_next_slab_axes
  ca_iter_state_sync_slab
  ca_iter_state_finish
]

# Enum / status tokens authors write literally at a macro call site or in
# a raw-API kernel (`flags` arg, `policy` arg, rc compare).
FROZEN_TOKENS = %w[
  CA_SLAB_AXES
  CA_KERNEL_WRITE
  CA_KERNEL_NO_MASK
  CA_ITER_OK
  CA_ITER_ERR_NOT_CHEAP
  CA_ITER_ERR_POLICY
  CA_ITER_ERR_FLAGS
  CA_ITER_ERR_READONLY
  CA_ITER_ERR_MASK
  CA_ITER_ERR_MASK_NOT_ALLOWED
]

# Slab-delivery representation: the `ca_iter_state` fields a kernel reads
# (directly in a hand-written walk, or via the body macros).  Freezing
# these is what lets the engine be re-implemented while hand-written
# kernels keep working.  Checked as a struct field declaration
# `<type> <name>` — we match the name as a word followed by `[` or `;`.
FROZEN_STATE_FIELDS = %w[
  slab_ndim
  slab_dims
  slab_strides
  slab_mask_strides
  slab_elements
  outer_ndim
  outer_axes
  outer_dims
]

# ---------------------------------------------------------------------------

src = File.read(HEADER, encoding: "UTF-8")

errors = []

def macro_defined?(src, name)
  src.match?(/^\s*#\s*define\s+#{Regexp.escape(name)}\s*\(/)
end

def token_defined?(src, name)
  # `#define NAME value` (object-like macro) OR `NAME = n` (enum member).
  src.match?(/^\s*#\s*define\s+#{Regexp.escape(name)}\s+/) ||
    src.match?(/\b#{Regexp.escape(name)}\s*=/)
end

def func_declared?(src, name)
  src.match?(/\b#{Regexp.escape(name)}\s*\(/)
end

def field_declared?(src, name)
  # e.g. `int8_t  slab_ndim;` or `ca_size_t slab_dims[CA_RANK_MAX];`
  src.match?(/\b#{Regexp.escape(name)}\s*(\[|;)/)
end

FROZEN_MACROS.each do |m|
  errors << "FROZEN macro missing/renamed: #{m}" unless macro_defined?(src, m)
end
FROZEN_FUNCS.each do |f|
  errors << "FROZEN raw-API entry missing/renamed: #{f}" unless func_declared?(src, f)
end
FROZEN_TOKENS.each do |t|
  errors << "FROZEN enum/status token missing/renamed: #{t}" unless token_defined?(src, t)
end
FROZEN_STATE_FIELDS.each do |fld|
  errors << "FROZEN state field missing/renamed: #{fld}" unless field_declared?(src, fld)
end

total = FROZEN_MACROS.size + FROZEN_FUNCS.size +
        FROZEN_TOKENS.size + FROZEN_STATE_FIELDS.size

if errors.empty?
  puts "OK: all #{total} frozen kernel_iterator author-surface names present."
  puts "    (#{FROZEN_MACROS.size} macros, #{FROZEN_FUNCS.size} raw-API, " \
       "#{FROZEN_TOKENS.size} tokens, #{FROZEN_STATE_FIELDS.size} state fields)"
  exit 0
else
  warn "FROZEN kernel_iterator surface drift detected:"
  errors.each { |e| warn "  - #{e}" }
  warn ""
  warn "These names are pinned by docs/authoring/HOW_TO_WRITE_KERNEL.md §0/§13 and the"
  warn "banner in ext/ca_kernel_iterator.h.  If a rename is truly intended"
  warn "(3.x breaking, author-facing), update both the doc contract and this"
  warn "guard in the SAME commit so the freeze stays honest."
  exit 1
end
