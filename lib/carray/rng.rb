class CArray

  # A random number generator with its own state.
  #
  # `Rng` rather than `Random`: a `CArray::Random` would shadow `::Random`
  # for every bare `Random` written inside `class CArray`, and the two mean
  # different generators -- `random!(rng: Random.new(4))` draws through
  # Ruby's MT19937 and `random!(rng: CArray::Rng.new(seed: 4))` through the
  # one below.  Two names that different should not look alike.
  #
  # The class itself is defined in ext/carray_random.c, which is where the
  # state is advanced.  What is added here is the generator's source text,
  # so that another gem can run the same code rather than a second
  # implementation of it.
  class Rng

    # The generators this carray knows, and how many int64 cells each one
    # keeps its state in.
    STATE_CELLS = {
      :xoshiro256pp => 4,
    }.freeze

    GENERATORS = STATE_CELLS.keys.freeze

    # Where a generator's C lives.  Shipped: the gemspec takes ext/*.h,
    # and `ext` is a require path, so this resolves in a checkout and in
    # an installed gem alike -- lib/ and ext/ are siblings in both.
    SOURCE_FILES = {
      :xoshiro256pp => File.expand_path("../../ext/ca_rng_xoshiro256pp.h",
                                        __dir__),
    }.freeze

    # The C each generator is, as text.
    #
    #   CArray::Rng::SOURCE[:xoshiro256pp]   #=> "/* ---- ... */\n..."
    #
    # This is the same text the extension compiled -- the file below is
    # `#include`d by ext/carray_random.c -- which is the point of handing
    # it out.  A caller that pastes it into a translation unit of its own
    # gets a generator that continues a sequence this one started, because
    # it is running the code this one ran and not a copy of it.
    #
    # carray-jit is the caller this exists for: a kernel's `random(rng:)`
    # pastes the text beside the helpers its own compiler emits, so a
    # kernel draws from the CArray::Rng it was handed.  The text needs
    # nothing but <stdint.h> and defines only `static inline` functions
    # under a `ca_` prefix.
    #
    # It is read once, when this file is first required.
    SOURCE = SOURCE_FILES.transform_values { |path|
      File.read(path, :encoding => "UTF-8")
    }.freeze

    # What every generator's text needs beside it, and what none of them
    # owns: turning uniforms into a normal is the same arithmetic whichever
    # generator the uniforms came from.
    #
    # Handed out apart from SOURCE because whoever pastes it pastes it once,
    # however many generators are drawing.  Folded into each generator's own
    # text instead, two generators in one translation unit would define it
    # twice.
    COMMON_SOURCE = File.read(
      File.expand_path("../../ext/ca_rng_normal.h", __dir__), :encoding => "UTF-8"
    ).freeze

    # The functions in SOURCE a caller may reach, by generator and by what
    # the draw answers: `:random` a double in [0.0, 1.0), `:randomn` a
    # standard normal, `:bits` the raw word a draw came from.  Each takes the
    # state and advances it -- `:randomn` by two draws, the other two by one.
    #
    # Named here rather than worked out by whoever pastes the text: which
    # symbols are the entry points is a fact about the generator, and the
    # generator is CArray's.  These are the three `#random`, `#randomn`
    # and `#bits` call, so a caller pasting the text draws the sequence
    # this one draws.
    DRAW_FUNCTIONS = {
      :xoshiro256pp => {
        :random  => "ca_xoshiro256pp_next_real",
        :randomn => "ca_xoshiro256pp_next_normal",
        :bits    => "ca_xoshiro256pp_next",
      }.freeze,
    }.freeze

  end

end
