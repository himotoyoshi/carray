ruby utils/extract_rdoc.rb > rdoc_ext.rb
rdoc -U -m rdoc_main.rb \
        rdoc_main.rb \
        rdoc_ext.rb \
        rdoc_math.rb \
        rdoc_stat.rb \
        lib/carray/*.rb \
        lib/carray/{base,graphics,io,math,object}/*.rb \
        ruby_carray.c