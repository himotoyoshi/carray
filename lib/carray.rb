# main

require 'carray_ext'

# Top-level CAMath module -- math namespace for CArrays.
# `CAMath.sin(ca)` works because module functions inherited
# from Math (via include) accept any object that responds to
# the corresponding instance method; CArray defines those in
# C.
module CAMath
  include Math
end

# carray/inspect is loaded lazily via autoload_carray (#inspect / #source_code
# stubs). #inspect fires on the first p / pp / irb display or error-message
# interpolation, so compute programs that never print a CArray skip it.
require 'carray/construct'
require 'carray/data_type_extension'
# carray/stack is loaded lazily via autoload_carray (entry-method stubs).
# CAStack is C-defined so its constant is always present; only the Ruby
# composition surface (stack/meld/montage/split/append) needs the file.
require 'carray/runtime'  # load-bearing Ruby support the core depends on
require 'carray/basics'   # frequently-used convenience methods kept eager
require 'carray/conditional'  # then_else / replace_where / conditional
require 'carray/mask_gap_fill'  # unmask/strip_mask method: keyword (hold / linear gap-fill)
require 'carray/attribute' # per-instance metadata Hash (#attribute / #has_attribute?)
require 'carray/boolean_reduce' # all/any/none skip_masked: keyword (Kleene fold)
require 'carray/meld_reduce'    # CAMeld per-parent reduce fast path (sum/mean/min/max along meld_axis)
# carray/ordering CIFY (2026-06-21): translated to ext/carray_order.c

require 'carray/math'
# carray/clip_cast CIFY (2026-06-23): translated to ext/carray_cast.c
require 'carray/complex' # real / imag accessors; MUST precede carray/lazy
                         # (lazy aliases real/imag at load time)
require 'carray/lazy'   # PROPOSAL_LAZY_ELEMENTWISE_VIEW Phase 1 P.1.2
# carray/face.rb was deleted (the Phase 1 skeleton CArray::Face module
# became dead weight, replaced by C-layer macro deploy +
# copy_state/storage_to_scalar convention).
require 'carray/time'  # CATime / CATimedelta (PROPOSAL_CAFACE_PHASE_2 F.2.4)
# carray/methods/* (bincount / broadcast / gather_nd+put_nd) are small
# single-feature method files, loaded lazily via autoload_carray.
require 'carray/iterator'
# carray/struct is loaded lazily via autoload_carray (constant + entry-method
# stubs). Nothing in the eager core references CAStruct/CAUnion, so programs
# that only use numeric arrays never pay its load cost.
require 'carray/string_operation_extension'  # shared StringOperationMixin (must precede the Faces)
require 'carray/const_string'   # PROPOSAL_CATEXT.md T.2 — CAConstString construction surface
require 'carray/string'         # PROPOSAL_STRING_FACE_TRIO.md P.1 — CAString construction surface
require 'carray/fixlen_string'  # PROPOSAL_STRING_FACE_TRIO.md P.1 — CAFixlenString construction surface
# CArray.format lives in carray/methods/string_format.rb, autoloaded on first call

# carray/frame is loaded lazily via autoload_carray (CAFrame / GroupedFrame
# constants). Nothing in the eager core references the frame, so programs that
# only use arrays never pay its load cost.

# opt-in refinements (loaded on first reference to the constant)

class CArray
  autoload :CoreExtensions, 'carray/core_extensions'
end

# autoload

require 'carray/autoload_method_extension'

class CArray
  extend AutoloadMethodExtension
end

require 'carray/autoload_carray'
