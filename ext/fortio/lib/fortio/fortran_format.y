# ----------------------------------------------------------------------------
#
#  carray/io/fortran_format.y
#
#  This file is part of Ruby/CArray extension library.
#  You can redistribute it and/or modify it under the terms of
#  the Ruby Licence.
#
#  Copyright (C) 2005 Hiroki Motoyoshi
#
# ----------------------------------------------------------------------------

#
#  racc fortran_format.y -> fortan_format.tab.rb
#

class FortranFormatParser

rule

  format :       
               format_string    { 
	                                if val[0].size == 1 and val[0].first.is_a?(Group)
		                                result = val[0].first
		                              else
	                                  result = Group.new(1,val[0]) 
	                                end
	                              }

  format_string : 
                 format_spec    { result = [val[0]] }
               | format_string format_spec 
                                { result = val[0] + [val[1]] }

  format_spec : 
                 hollerith      { result = val[0] }
               | unrepeatable   { result = val[0] }
               | repeatable     { result = val[0] }
               | DIGITS repeatable 
                                { val[1].count = val[0]; result = val[1] }

  hollerith    : H              { result = NodeH.new(*val[0]) }

  unrepeatable : 
                 STRING         { result = NodeS.new(val[0]) }
               | P              { result = NodeP.new(val[0]) }
               | Sp             { result = NodeSp.new(val[0]) }
               | B              { result = NodeB.new(val[0]) }
               | T              { result = NodeT.new(val[0]) }
               | TR             { result = NodeTR.new(val[0]) }
               | TL             { result = NodeTL.new(val[0]) }
               | '$'            { result = Continue.new }

  repeatable : 
                 '(' format_string ')' 
                                { result = Group.new(1,val[1]) }
               | fixed_point
               | floating_point
               | '/'            { result = Flush.new(1) }

  fixed_point : 
                 X              { result = NodeX.new(1) }
               | A              { result = NodeA.new(1, val[0]) }
               | I              { result = NodeI.new(1, *val[0]) }
               | L              { result = NodeL.new(1, *val[0]) }
               | F              { result = NodeF.new(1, *val[0]) }

  floating_point : 
                 E              { result = NodeE.new(1, *val[0]) }
               | ES             { result = NodeES.new(1, *val[0]) }
               | D              { result = NodeE.new(1, *val[0]) }
               | G              { result = NodeG.new(1, *val[0]) }  
               | floating_point EXP 
                                { result = val[0]; result.exp = val[1] }

end

---- inner

  def parse (str)
    @scan  = FortranFormatScanner.new(str)
    @scale = 0
    @continue = false
    do_parse
  end

  def next_token
    return @scan.yylex
  end

---- header

require "strscan"

class FortranFormatScanner 
  
  def initialize (text)
    @s = StringScanner.new(text)
  end

  def yylex
    while @s.rest?
      case
      when @s.scan(/\A(ES|[FEDG])(\d+)\.(\d+)/i) ### {F|E|D|G|ES}w.d
        return [
          @s[1].upcase.to_sym, 
          [
            @s[2].to_i, 
            @s[3].to_i
          ]
        ]
      when @s.scan(/\AE(\d+)/i)               ### Ed (for exponential)
        return [
          :EXP,
          @s[1].to_i
        ]
      when @s.scan(/\AI(\d+)(\.(\d+))?/i)     ### Iw(.d)
        return [
          :I, 
          [
            @s[1].to_i, 
            @s[3] ? @s[3].to_i : nil
          ]
        ]
      when @s.scan(/\AL(\d+)?/i)              ### L(w)
        return [
          :L, 
          @s[1] ? @s[1].to_i : nil
        ]
      when @s.scan(/\AA(\d+)?/i)              ### A(w)
        return [
          :A, 
          @s[1] ? @s[1].to_i : nil
        ]
      when @s.scan(/\AX/i)                    ### X
        return [
          :X,
          nil
        ]
      when @s.scan(/\ATL(\d+)?/i)             ### TLw
        return [
          :TL,
          @s[1] ? @s[1].to_i : 1
        ]
      when @s.scan(/\ATR(\d+)?/i)             ### TRw
        return [
          :TR,
          @s[1] ? @s[1].to_i : 1
        ]
      when @s.scan(/\AT(\d+)?/i)              ### Tw
        return [
          :T,
          @s[1] ? @s[1].to_i : 1
        ]
      when @s.scan(/\A([+-]?\d+)P/i)          ### {+|-|}P
        return [
          :P,
          @s[1].to_i
        ]
      when @s.scan(/\AS[PS]?/i)               ### S,SP,SS
        return [
          :Sp,
          @s[0] =~ /SP/i ? true : false
        ]
      when @s.scan(/\AB[NZ]/i)                ### BN,BZ
        return [
          :B,
          @s[0] =~ /BZ/i ? true : false
        ]
      when @s.match?(/\A(\d+)?H/i)            ### Hollerith 
        count  = @s[1] ? @s[1].to_i : 1
        if @s.scan(/\A(\d+)?H(.{#{count}})/)
          return [
            :H,
            [count, @s[2]]
          ]
	      else
					raise "invalid horeris descriptor"
        end
      when @s.scan(/\A'((?:''|[^'])*)'/)      ### 'quoted string'
        return [
          :STRING, 
          @s[1].gsub(/''/, "'")
        ]
      when @s.scan(/\A"((?:""|[^"])*)"/)      ### 'double-quoted string'
        return [
          :STRING, 
          @s[1].gsub(/""/, '"')
        ]
      when @s.scan(/\A(\d+)/)                 ### digits
        return [
          :DIGITS, 
          @s[1].to_i
        ]
      when @s.scan(/\A([\(\)\/\$\:])/)        ### {(|)|/|$}
        return [
          @s[1], 
          nil
        ]
      when @s.scan(/:/)
	      raise("format descriptor ':' is not supported.")
      when @s.scan(/\A,/)                     ### blank
        next
      when @s.scan(/\A\s+/)                   ### blank
        next
      else
        raise "FortranFormat parse error\n\t#{@s.string}\n\t#{' '*@s.pos}^"
      end
    end
  end

end

---- footer

