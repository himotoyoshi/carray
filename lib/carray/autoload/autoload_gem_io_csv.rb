autoload_method "CArray.load_csv", "carray-io-csv"
autoload_method "CArray.from_csv", "carray-io-csv"

class CArray
  autoload_method "save_csv", "carray-io-csv"
  autoload_method "to_csv", "carray-io-csv"
  autoload_method "to_tabular", "carray-io-csv"
end

module CA
  autoload :CSVReader, "carray-io-csv"
  autoload :CSVWriter, "carray-io-csv"
end

