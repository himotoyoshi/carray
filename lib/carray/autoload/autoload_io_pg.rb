autoload_method "CArray.load_pg", "carray/io/pg"

class CArray
  autoload_method "unescape_bytea", "carray/io/pg"
  autoload_method "escape_bytea", "carray/io/pg"
end