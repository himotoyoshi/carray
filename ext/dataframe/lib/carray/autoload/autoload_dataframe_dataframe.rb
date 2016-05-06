
module CA::TableMethods
  autoload_method "to_dataframe", "carray/dataframe/dataframe"
end

autoload :CADataFrame, "carray/dataframe/dataframe"

autoload :DataFrame, "carray/dataframe/dataframe"
autoload :RSReceiver, "carray/dataframe/dataframe"

class RSRuby
  autoload_method "setup", "carray/dataframe/dataframe"
  autoload_method "recieve", "carray/dataframe/dataframe"
end
