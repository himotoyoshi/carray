require "spreadsheet"

class CArray
  
  def save_excel (filename, &block)
    if self.rank >= 3
      raise "too large rank (>2) to write excel file"
    end
    book = Spreadsheet::Workbook.new
    worksheet = book.create_worksheet
    self.dim0.times do |i|
      worksheet.row(i).push *self[i,nil]
    end
    if block
      block.call(worksheet)
    end
    book.write(filename)    
  end
  
  def self.load_excel (filename, sheet=0)
    book = Spreadsheet.open(filename)
    sheet = book.worksheet(sheet)
    return sheet.map(&:to_a).to_ca
  end
  
end