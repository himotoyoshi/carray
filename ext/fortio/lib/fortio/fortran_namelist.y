# ----------------------------------------------------------------------------
#
#  carray/io/fortran_namelist.y
#
#  This file is part of Ruby/CArray extension library.
#  You can redistribute it and/or modify it under the terms of
#  the Ruby Licence.
#
#  Copyright (C) 2005 Hiroki Motoyoshi
#
# ----------------------------------------------------------------------------

#
#  racc fortran_namelist.y -> fortan_namelist.tab.rb
#

class FortranNamelistParser

prechigh
  left COMMA
  left ','
  left '='
preclow

rule

  namelist_all : 
                 namelist
               | namelist namelist_all

  namelist : 
                 header paramlist tailer 
                           { @root[val[0]] = val[1]; @scan.in_namelist = false }

  header : 
                 '&' IDENT { result = val[1].downcase }
               | '$' IDENT { result = val[1].downcase }

  tailer :
                 '$'
               | '&'
               | '/'
               | '&' IDENT { on_error unless val[1] =~ /\Aend\Z/i }
               | '$' IDENT { on_error unless val[1] =~ /\Aend\Z/i }

  paramlist:
                 paramdef  { result = [val[0]] }
               | paramlist paramdef
                           { result = val[0] + [val[1]] }
               | paramlist COMMA paramdef
                           { result = val[0] + [val[2]] }
               | paramlist COMMA
                           { result = val[0] }

  paramdef:  
                 IDENT '=' rvalues 
                           { result = ParamDef.new(val[0].downcase.intern, nil, val[2]) }
               | IDENT '(' array_spec ')' '=' rvalues  
                           { result = ParamDef.new(val[0].downcase.intern, val[2], val[5]) }

  rvalues :      
                 abbreb    { result = val[0] }
               | rvalues abbreb      
                           { result = val[0] + val[1] }
               | rvalues NIL
                           { result = val[0] + [nil] }
               | rvalues ',' abbreb
                           { result = val[0] + val[2] }
               | IDENT
                           { result = val[0] }

  abbreb :
                 constant { result = [val[0]] }
               | DIGITS '*' constant
                          { result = [val[2]] * val[0] }

  constant :
                 STRING
               | DIGITS
               | FLOAT

  array_spec :
                 DIGITS    { result = [val[0]-1] }
               | DIGITS ':' DIGITS     
                           { result = [(val[0]-1)..(val[2]-1)] }
               | DIGITS ',' array_spec 
                           { result = [val[0]-1] + val[2] }
               | DIGITS ':' DIGITS ',' array_spec
                           { result = [(val[0]-1)..(val[2]-1)] + val[4] }

end

---- inner

  def parse (str)
    @scan = FortranNamelistScanner.new(str)
    @root = {}
    do_parse
    return @root
  end

  def next_token
    return @scan.yylex
  end

---- header

require "strscan"
require "stringio"

class FortranNamelistScanner 
  
  def initialize (text)
    @s = StringScanner.new(text)
    @in_namelist = false
  end

  attr_accessor :in_namelist

  def yylex
    while @s.rest?
      unless @in_namelist
        case
        when @s.scan(/\A([\$&])/)              ### {$|&}
          @in_namelist = true
          return [
            @s[0], 
            nil
          ]
        when @s.scan(/\A[^\$&]/)
          next
        end       
      else
        case
        when @s.scan(/\A[+-]?(\d+)\.(\d+)?([ED][+-]?(\d+))?/i) ### float
          return [                              ### 1.2E+3, 1.E+3, 1.2E3
            :FLOAT,                             ### 1.2, 1.
            @s[0].sub(/D/i,'e').sub(/\.e/,".0e").to_f
          ]
        when @s.scan(/\A[+-]?\.(\d+)([ED][+-]?(\d+))?/i)       ### float
          return [                              ### .2E+3, -.2E+3, .2E3
            :FLOAT,                             ### .2, -.2
            @s[0].sub(/D/i,'e').sub(/\./, '0.').to_f
          ]
        when @s.scan(/\A[+-]?(\d+)[ED][+-]?(\d+)/i)            ### float
          return [                              ### 12E+3, 12E3, 0E0
            :FLOAT, 
            @s[0].sub(/D/i,'e').to_f
          ]
        when @s.scan(/\A[\-\+]?\d+/)            ### digits
          return [
            :DIGITS, 
            Integer(@s[0])
          ]
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
        when @s.scan(/\A,/)                     ### ,
          @s.scan(/\A\s+/)
          while @s.scan(/\A\n\s*/) or @s.scan(/\A\![^\n]*/)
            ### skip comment
          end
          if @s.match?(/\A[a-z]\w*/i) or @s.match?(/\A[\&\$\/\!]/)
            return [
              :COMMA, 
              nil
            ]
          elsif @s.match?(/\A,/)
            return [
              :NIL,
              nil
            ]
          else
            return [
              ',',
              nil
            ]
          end
        when @s.scan(/\A[\$&\/=\(\):*]/)        ### {$|&|/|,|=|(|)|:|*}
          return [
            @s[0], 
            nil
          ]
        when @s.scan(/\A[a-z]\w*/i)             ### IDENT
          return [
            :IDENT,
            @s[0]
          ]
        when @s.scan(/\A\s+/)                   ### blank
          next
        when @s.scan(/\A![^\n]*?\n/)             ### comment
          next
        when @s.scan(/\A\n/)                    ### newline
          next
        else
          @s.rest =~ /\A(.*)$/
          raise "FortranFormat parse error\n\t#{$1}\n\t^"
        end
      end
    end
  end

end

---- footer

