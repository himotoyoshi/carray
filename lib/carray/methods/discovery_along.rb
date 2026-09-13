class CArray

  #  The value-hash discovery family (`unique`, `nunique`,
  #  `mask_duplicates`, ...) interns one **cell** at a time.  `along:`
  #  widens the unit to a whole sub-array: the sub-arrays enumerated
  #  along one axis, each compared as a single value.
  #
  #  Nothing new has to hash.  `fz_hash`'s third key lane already interns
  #  a fixed-width block of bytes (FNV-1a, with a memcmp re-check), which
  #  is what a sub-array is once it sits contiguously; this method is the
  #  bridge to it, and the three things the bridge has to get right:
  #
  #    - the sub-arrays have to be contiguous before their bytes mean
  #      anything, which a transpose or a strided view does not give;
  #    - byte equality is not the family's contract for floats, where
  #      every NaN is one value and -0.0 is +0.0;
  #    - masks fold for free -- a CARefer that covers several parent
  #      cells with one view cell OR-reduces their mask bits, so a
  #      sub-array holding a masked cell is a masked sub-array and the
  #      kernels skip it.
  #
  #  Returns a 1-D fixlen array, one cell per sub-array, for the caller
  #  to run an ordinary cell-level discovery method over.
  private def fibers_as_cells (along, caller_name)
    if ndim < 2
      raise ArgumentError,
            "#{caller_name}: along: compares sub-arrays, and a #{ndim}-D array " \
            "has none -- drop along: for the whole-array form"
    end

    if data_type == CA_OBJECT
      raise ArgumentError,
            "#{caller_name}: along: is not available for an object array -- " \
            "its cells hold Ruby references, which would compare by identity " \
            "rather than by value"
    end

    axis = normalize_axis(along, caller_name)

    #  Bring the named axis to the front so each sub-array is one
    #  unbroken run of bytes, and take a copy: `refer` reinterprets a
    #  byte buffer, and a view whose element stride is not its element
    #  width is not one.  The copy is also what makes the normalisation
    #  below safe to write.
    order = [axis] + (0...ndim).to_a.reject { |i| i == axis }
    block = (axis.zero? ? self : transpose(*order)).copy

    #  Two values the family calls equal are not equal byte for byte.
    #  Normalise them so the bytes say what the values mean.
    if block.float?
      block[:is_nan] = Float::NAN     #  every NaN is one value
      block[:eq, 0.0] = 0.0           #  -0.0 is +0.0
    elsif block.complex?
      [block.real, block.imag].each do |part|
        part[:is_nan] = Float::NAN
        part[:eq, 0.0] = 0.0
      end
    end

    count = shape[axis]
    block.refer(:fixlen, [count], bytes: elements / count * bytes)
  end

  #  `axis:` and `along:` ask different questions of the same array, so
  #  answering both at once has no meaning.
  private def reject_axis_with_along (axis, along, caller_name)
    return unless axis and along
    raise ArgumentError,
          "#{caller_name}: axis: and along: cannot be given together -- " \
          "axis: is about the values inside each sub-array, along: is about " \
          "the sub-arrays themselves"
  end

end
