# ----------------------------------------------------------------------------
#
#  carray/autoload_carray.rb
#
#  Autoload stubs for CArray's Ruby-side surface.  Loaded from lib/carray.rb
#  after autoload_method_extension is installed.  Split by intent:
#
#    (1) Top-level feature files under carray/ — constant class + entry
#        methods (Serializer, TableMethods, iterators, aggregation
#        accumulators, categorical / axis-group).
#    (2) Single-feature method files under carray/methods/ — each first
#        call requires its file, whose definitions overwrite the stubs
#        and re-dispatch.  None of these methods has internal callers,
#        so they never load unless user code uses them.
#
# ----------------------------------------------------------------------------


# ============================================================================
# (1) Top-level feature files
# ============================================================================

# ---- Inspection (#inspect / #source_code) ----------------------------------
#
# CArray::Inspector (:nodoc:) and #inspect / #source_code live in carray/inspect.rb.
# #inspect is an implicit method (p / pp / irb / error interpolation), so the
# stub loads the file the first time any CArray is displayed. Nothing in the
# eager core references it at load time; #desc is private (code-internal) and
# Inspector is internal, so only the two public methods need stubs.

class CArray
  inspect_rb = "carray/inspect"
  autoload_method "inspect",     inspect_rb
  autoload_method "source_code", inspect_rb
end

# ---- Serializer / Marshal / dump / load ------------------------------------

class CArray
  serialize_rb = "carray/serialize"
  autoload :Serializer, serialize_rb
  autoload_method "self.save",           serialize_rb
  autoload_method "self.load",           serialize_rb
  autoload_method "self.dump",           serialize_rb
  autoload_method "self.load_from_file", serialize_rb
  autoload_method "marshal_dump",        serialize_rb
  autoload_method "marshal_load",        serialize_rb
end

# ---- Arrow tensor IPC (interop) --------------------------------------------

class CArray
  arrow_tensor_rb = "carray/arrow_tensor"
  autoload :ArrowTensor, arrow_tensor_rb
  autoload_method "self.load_arrow_tensor", arrow_tensor_rb
  autoload_method "save_arrow_tensor",      arrow_tensor_rb
end

# ---- Table (row-major dispatch helper) -------------------------------------

class CArray
  autoload :TableMethods, "carray/table"
end

# ---- Iterators (class / slab) ----------------------------------------------

autoload :CASlabIterator,   "carray/slab_iterator"
autoload :CAWindowIterator, "carray/window_iterator"
autoload :CABlockIterator,  "carray/block_iterator"

class CArray
  autoload_method "windows", "carray/window_iterator"
  autoload_method "blocks",  "carray/block_iterator"
end

# ---- Aggregation accumulators (histogram / bincount_nd) --------------------

class CArray
  histogram_rb = "carray/histogram"
  autoload :Histogram, histogram_rb
  autoload_method "histogram1d", histogram_rb
  autoload_method "histogram2d", histogram_rb
  autoload_method "histogram",   histogram_rb

  bincount_nd_rb = "carray/bincount_nd"
  autoload :BincountND, bincount_nd_rb
  autoload_method "bincount_nd", bincount_nd_rb
end

# ---- Categorical / Axis-group reduction ------------------------------------
#
# Classifier is CACategorical; axis_group builds the reduction spec.
# AxisGroup / GroupLabels are top-level;
# CAGroupIterator is C-defined (ext/ca_group_iter.c), no autoload.
# The C `[]` type gate (ext/ca_group_iter.c) arms itself lazily the first
# time a fixlen-surface CArray index appears, so a categorical from any
# construction path (`categorize` / CACategorical.from_codes) is recognised
# without routing categorical's autoload through this file (which would
# recurse when categorical.rb reopens `class CACategorical`).

class CArray
  categorical_rb = "carray/categorical"
  autoload_method "categorize", categorical_rb

  axis_group_rb = "carray/axis_group"
  autoload_method "axis_group", axis_group_rb

  categorical_iterator_rb = "carray/categorical_iterator"
  autoload_method "group_by_category", categorical_iterator_rb
  autoload_method "group_by_run", categorical_iterator_rb
end

autoload :CACategorical,          "carray/categorical"
autoload :CACategoricalIterator,  "carray/categorical_iterator"
autoload :AxisGroup,              "carray/axis_group"
autoload :GroupLabels,            "carray/axis_group"


# ---- CAStruct / CAUnion (fixlen data_class DSL) ----------------------------
#
# The struct/union surface is only reached through CArray.struct / .union
# (definition) or the CAStruct / CAUnion constants (subclassing, rescue
# CAStruct::Error). Nothing in the eager core references it, so it loads on
# first use. CAStruct::Builder stays nested-autoloaded inside struct.rb.

autoload :CAStruct, "carray/struct"
autoload :CAUnion,  "carray/struct"

# ---- CAFrame (DataFrame over CArray columns) -------------------------------
#
# The frame is only reached through the CAFrame constant (CAFrame.new /
# .from_csv / subclassing) or GroupedFrame (obtained from CAFrame#group_by,
# by which point CAFrame is already loaded). Both constants live in the same
# require bundle (carray/frame.rb), so autoloading either loads the whole
# frame. Nothing in the eager core references them, so it loads on first use.

autoload :CAFrame,      "carray/frame"
autoload :GroupedFrame, "carray/frame"

class CArray
  struct_rb = "carray/struct"
  autoload_method "self.struct", struct_rb
  autoload_method "self.union",  struct_rb
  autoload_method "st",          struct_rb
end

# ---- CAStack composition surface (stack / meld / montage / split / append) --
#
# CAStack is C-defined (ext/ca_obj_stack.c), so its constant and raw
# `CAStack.new` are always present without this file. Only the Ruby
# composition surface lives in carray/stack.rb; nothing in the eager core
# calls it (promote_list / normalize_axis are C-defined), so it loads on
# first use. CAStack#append needs its own stub, so CAStack extends the DSL.

class CArray
  stack_rb = "carray/stack"
  autoload_method "self.stack",   stack_rb
  autoload_method "self.meld",    stack_rb
  autoload_method "self.montage", stack_rb
  autoload_method "stack",        stack_rb
  autoload_method "meld",         stack_rb
  autoload_method "split",        stack_rb
end

class CAStack
  extend AutoloadMethodExtension
  autoload_method "append", "carray/stack"
end


# ============================================================================
# (2) Single-feature method files under carray/methods/
# ============================================================================

# ---- per_cell --------------------------------------------------------------
#
# CArray.per_cell runs a per-cell computation over an index space -- the
# surface an array algorithm is written on.  Nothing in the core calls it, so
# the file loads only when user code does.
#
# carray/methods/per_cell.rb holds the interpreted form and is the stub the
# carray-jit gem replaces: `require "carray/jit"` overwrites the method with
# one that compiles the block to C.  Loading order takes care of itself, since
# carray/jit requires carray first.

class CArray
  autoload_method "self.per_cell", "carray/methods/per_cell"
end

class CArray
  # composition family (eager ragged list -> one array)
  autoload_method "self.concatenate", "carray/methods/composition"
  autoload_method "concatenate",      "carray/methods/composition"
  autoload_method "self.mosaic",      "carray/methods/composition"
  autoload_method "self.tabulate",    "carray/methods/composition"

  autoload_method "self.meshgrid",  "carray/methods/meshgrid"

  autoload_method "bincount",       "carray/methods/bincount"
  autoload_method "self.broadcast", "carray/methods/broadcast"
  autoload_method "gather_nd",      "carray/methods/gather_nd"
  autoload_method "put_nd",         "carray/methods/gather_nd"
  autoload_method "mask_duplicates", "carray/methods/mask_duplicates"
  autoload_method "unique",          "carray/methods/unique"
  autoload_method "is_in",           "carray/methods/is_in"
  autoload_method "intersection",    "carray/methods/is_in"
  autoload_method "difference",      "carray/methods/is_in"
  autoload_method "union",           "carray/methods/is_in"
  autoload_method "self.align_addr",         "carray/methods/align_addr"
  autoload_method "self.align_nearest_addr", "carray/methods/align_addr"
  autoload_method "value_counts",    "carray/methods/value_counts"
  autoload_method "nunique",         "carray/methods/nunique"
  autoload_method "is_mode",         "carray/methods/mode"
  autoload_method "mode",            "carray/methods/mode"
  autoload_method "snap",           "carray/methods/snap"
  autoload_method "snap_to",        "carray/methods/snap"
  autoload_method "bin",            "carray/methods/bin"
  autoload_method "bin_to",         "carray/methods/bin"
  autoload_method "index",          "carray/methods/index"
  autoload_method "indices",        "carray/methods/index"
  autoload_method "to_bit_string",       "carray/methods/bit_string"
  autoload_method "from_bit_string",     "carray/methods/bit_string"
  autoload_method "self.from_bit_string", "carray/methods/bit_string"
  autoload_method "pack_bits",           "carray/methods/bit_string"
  autoload_method "validity_bits",       "carray/methods/bit_string"
  autoload_method "choose",         "carray/methods/choose"
  autoload_method "join",           "carray/methods/join"
  autoload_method "locate_addr",         "carray/methods/locate_addr"
  autoload_method "locate_nearest_addr", "carray/methods/locate_addr"
  autoload_method "resize",         "carray/methods/resize"
  autoload_method "insert_block",   "carray/methods/insert_block"
  autoload_method "delete_block",   "carray/methods/insert_block"
  autoload_method "self.format",    "carray/methods/string_format"
  autoload_method "format",         "carray/methods/string_format"
end
