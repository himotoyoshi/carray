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
#               fields, and the macros only ext/mkkernel.rb emits: the
#               8-way SUM8 / MIN8 / MAX8 / STAR8 reductions,
#               CA_SLAB_REDUCE_T_MIN_EX / _MAX_EX / _STAR_EX,
#               CA_SLAB_REDUCE_SUM8_NARROW_EX / M2_NARROW_EX,
#               CA_SLAB_REDUCE_T_SETTLE / CA_SLAB_SETTLE_BLOCK,
#               CA_SLAB_SCAN_T_GATED, CA_SLAB_REDUCE_T_VAR_EX).  Free to
#               refactor across 3.x.
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
# `ruby utils/check_kernel_surface_freeze.rb`).

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
  CA_FOR_EACH_FIBER_PAIR
  CA_FOR_EACH_FIBER_PAIR_MASKED
  CA_FOR_EACH_WHOLE
  CA_FOR_EACH_WHOLE_MASKED
  CA_SLAB_REDUCE_T
  CA_SLAB_REDUCE_T_EX
  CA_SLAB_REDUCE_T_PLUS_EX
  CA_SLAB_REDUCE_ARRAY_T_EX
  CA_SLAB_REDUCE_ARRAY_T_PLUS_EX
  CA_SLAB_MAP_T
  CA_SLAB_SCAN_T
  CA_SLAB_SCAN_TA
  CA_FOR_EACH_UNMASKED
  CA_L2_FOR_EACH
]

# Raw-API entry points the macros expand to (also callable directly by
# kernels that need explicit error handling — see doc §6.3).
FROZEN_FUNCS = %w[
  ca_iter_state_init_l1
  ca_iter_state_next_slab
  ca_iter_state_init_l2
  ca_iter_state_init_l2_paired
  ca_iter_state_next_slab_axes
  ca_iter_state_sync_slab
  ca_iter_state_finish
  ca_iter_state_close
  ca_iter_check_init
  ca_iter_check_same_shape
  ca_iter_ensure
  ca_iter_register_source_kind
]

# Enum / status tokens authors write literally at a macro call site or in
# a raw-API kernel (`flags` arg, `policy` arg, rc compare).
FROZEN_TOKENS = %w[
  CA_SLAB_AXES
  CA_SLAB_WHOLE
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

# --- examples in the catalog -----------------------------------------------
# docs/authoring/HOW_TO_WRITE_KERNEL.md §0.1 names, for each macro, a
# function in the tree that uses it.  Check that the named function still
# uses the macro, and that every block macro has a row.  The example cell
# is `path` `function`, `path` alone (the file uses the macro), `none`, or
# a dash for a row that is not a macro.

ROOT    = File.expand_path("..", __dir__)
CATALOG_NAME = "docs/authoring/HOW_TO_WRITE_KERNEL.md"
CATALOG      = File.join(ROOT, CATALOG_NAME)

# The body of a C function -- from the line that starts with its name and
# an opening parenthesis to the next line that is a lone closing brace --
# or of a function-like macro, from its #define to the last continued line.
def c_function_body(text, name)
  lines = text.lines
  start = lines.index { |l| l.match?(/^#{Regexp.escape(name)}\s*\(/) }
  if start
    stop = lines[start..].index { |l| l.start_with?("}") }
    return stop && lines[start, stop + 1].join
  end
  start = lines.index { |l| l.match?(/^#\s*define\s+#{Regexp.escape(name)}\(/) }
  return nil unless start
  stop = start
  stop += 1 while stop < lines.size - 1 && lines[stop].rstrip.end_with?("\\")
  lines[start..stop].join
end

# ext/mkkernel.rb builds some macro names from parts, so a name missing
# from the generator is looked for in what it generated.  The generated
# files are not in the repository; before a build they cannot be read.
GENERATED = Dir[File.join(ROOT, "ext/carray_kernels_*.c")]
unchecked = []

catalog = File.read(CATALOG, encoding: "UTF-8")
section = catalog[/^### 0\.1 Catalog\n(.*?)^### 0\.2 /m, 1].to_s
header  = section.lines.find { |l| l.start_with?("| Macro |") }
example_col = header && header.split("|").map(&:strip).index("Example in the source")
examples = {}
if example_col.nil?
  errors << "catalog: no 'Example in the source' column in #{CATALOG_NAME} §0.1"
else
  section.lines.grep(/^\| `CA_/).each do |row|
    cells = row.split("|").map(&:strip)
    name  = cells[1][/`([A-Z0-9_]+)`/, 1]
    cell  = cells[example_col].to_s
    examples[name] = cell
    next if cell == "none" || cell == "—"
    path, func = cell.scan(/`([^`]+)`/).flatten
    file = path && File.join(ROOT, path)
    if file.nil? || !File.exist?(file)
      errors << "catalog: #{name}: example file not found: #{path.inspect}"
      next
    end
    text = File.read(file, encoding: "UTF-8")
    body = func ? c_function_body(text, func) : text
    if path == "ext/mkkernel.rb" && !body.match?(/\b#{Regexp.escape(name)}\b/)
      if GENERATED.empty?
        unchecked << name
        next
      end
      body = GENERATED.map { |g| File.read(g, encoding: "UTF-8") }.join
    end
    if body.nil?
      errors << "catalog: #{name}: no function #{func} in #{path}"
    elsif !body.match?(/\b#{Regexp.escape(name)}\s*\(/)
      errors << "catalog: #{name}: #{path} #{func || ""} no longer uses it"
    end
  end
end
FROZEN_MACROS.grep(/\ACA_FOR_EACH_(SLAB|FIBER|WHOLE)/).each do |m|
  errors << "catalog: block macro #{m} has no row in #{CATALOG_NAME} §0.1" unless examples.key?(m)
end

total = FROZEN_MACROS.size + FROZEN_FUNCS.size +
        FROZEN_TOKENS.size + FROZEN_STATE_FIELDS.size

if errors.empty?
  puts "OK: all #{total} frozen kernel_iterator author-surface names present."
  puts "    (#{FROZEN_MACROS.size} macros, #{FROZEN_FUNCS.size} raw-API, " \
       "#{FROZEN_TOKENS.size} tokens, #{FROZEN_STATE_FIELDS.size} state fields)"
  shown = examples.values.count { |c| c != "none" && c != "—" }
  puts "    catalog: #{shown} of #{examples.size} rows name an example still in use"
  unless unchecked.empty?
    puts "    catalog: not checked before a build (generated names): #{unchecked.join(", ")}"
  end
  exit 0
else
  warn "FROZEN kernel_iterator surface drift detected:"
  errors.each { |e| warn "  - #{e}" }
  warn ""
  warn "These names are pinned by docs/authoring/HOW_TO_WRITE_KERNEL.md §0/§13 and the"
  warn "banner in ext/ca_kernel_iterator.h.  If a rename is truly intended"
  warn "(3.x breaking, author-facing), update both the doc contract and this"
  warn "guard in the SAME commit so the freeze stays honest."
  warn ""
  warn "A catalog error means a row of #{CATALOG_NAME} §0.1 no longer names"
  warn "a function that uses its macro: point it at one that does, or write none."
  exit 1
end
