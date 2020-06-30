require "carray"

def guess_shape (ary)
  if ary.class == Array
    info = {
      :rank => 0,
      :dim => [],
      :stop_rank => 0,
    }
    (1..5).each do |rank|
      info[:rank] = rank
      guess_shape_rank(ary, info, 1)
      if info[:stop_rank] != 0
        return info[:dim]
      end
    end
    raise "too deep array"
  else
    return []  ### rank = 0
  end
end

# ok　0
# scalar => 1
# array invalid length => 2

def guess_shape_rank (ary, info, level)
  len = info[:dim][level-1]
  printf "len->#{len}\n"
  if len 
    if len != ary.length
      info[:stop_rank] = level-1
      return 2
    end
  else
    len = ary.length
    printf "len: set #{len}\n"
    info[:dim][level-1] = len
  end
  if level == info[:rank]
    return 0
  end
  if level < info[:rank]
    p ary
    ary.each do |e|
      if e.class == Array 
        retval = guess_shape_rank(e, info, level+1)
        case retval
        when 1, 2
          return retval
        when 0
        end
      else
        info[:stop_rank] = level
        info[:dim] = info[:dim][0..level-1]
        return 1
      end
    end
    return 0
  end
  return 3
end


ary = [
  [[[[3],3],1]],
  [[2,2]],
  [[3,3,]]
]
#ca = CArray.object(4,3,2,1).seq
#ca.elem_store([0,0,0,0],[1,2])
#ary = ca.to_a
p ary
p CArray.guess_array_shape(ary)
p guess_shape(ary)
p ary.to_ca
