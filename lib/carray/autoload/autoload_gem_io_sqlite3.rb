autoload_method "CArray.load_sqlite3", "carray-io-sqlite3"

class CArray
  autoload_method "unblob", "carray-io-sqlite3"
  autoload_method "to_sqlite3", "carray-io-sqlite3"
end

if Object.const_defined?(:SQLite3)
  require "carray-io-sqlite3"
else
  autoload :SQLite3, "carray-io-sqlite3"
end
