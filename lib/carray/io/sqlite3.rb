require "carray"
require "sqlite3"
require "carray/io/table"

class CArray
  
  def self.load_sqlite3 (expr, *args)
    case expr
    when String
      file = expr
      sql, *vars = *args
      db = SQLite3::Database.new(file)
      names, *table = db.execute2(sql, *vars)
      db.close
    when SQLite3::Database
      db = expr
      sql, *vars = *args
      names, *table = db.execute2(sql, *vars)
    when SQLite3::Statement
      stmt = expr
      vars = args
      names = stmt.columns
      table = stmt.execute!(*vars)
    else
      raise "invalid 1st arg"
    end
    table = table.to_ca
    table.extend(CA::TableMethods)
    table.column_names = names
    return table
  end

  def to_sqlite3 (database: nil, table:, datatype: "numeric", schema: nil, transaction: true)
    unless rank <= 2
      raise "to_sqlite3 is valid only for 2-dim array (table)"
    end
    case database
    when SQLite3::Database
    when String
      if File.exist? database
        database = SQLite3::Database.open(database)
      else
        database = SQLite3::Database.new(database)        
      end
    else
      database = SQLite3::Database.new ":memory:"
    end
    if respond_to?(:column_names) and column_names
      vars = column_names
    else
      if rank == 1
        vars = ["c0"]
      else
        vars = CArray.object(dim1).seq.map{|s| "c#{s}" }
      end
    end
    
    if schema
      database.execute "create table if not exists #{table} (" + schema + ")"          
    else
      database.execute "create table if not exists #{table} (" + vars.map{|s| s + " " + datatype }.join(",") + ")"
    end

    insert = database.prepare %{ insert or replace into #{table} values (#{(["?"]*vars.size).join(",")}) }
    database.transaction if transaction
    if rank == 1
      dim0.times do |i|
        insert.execute [self[i]]
      end
    else
      begin
        dim0.times do |i|
          begin
           insert.execute self[i,nil].to_a
          rescue
            puts self[i,nil].to_a
            raise $!
          end
        end
      end
    end
    database.commit if transaction
    insert.close
    return database
  end

  def unblob (type, subdim = nil)
    bytes = CArray.sizeof(type)
    elem  = self[0]
    if elem == nil and subdim == nil
      raise "first element is nil, please specify dimension."
    end
    unless subdim
      subdim = [elem.bytesize/bytes]
    end
    out = CArray.new(type, dim + subdim)
    needed_bytes = out.elements/self.elements*bytes
    ref = out.refer(:fixlen, dim, :bytes=>needed_bytes)
    if elem and needed_bytes != elem.bytesize 
      self.each_addr do |addr|
        if self[addr].nil?
          ref[[addr]] = UNDEF
        else
          ref[[addr]].load_binary self[addr]
        end
      end
    elsif self.any_equal?(nil)
      copy  = self.to_ca
      sel   = self.eq(nil)
      copy[sel] = "\0" * needed_bytes
      ref.load_binary copy.join
      ref[sel] = UNDEF
    else
      ref.load_binary self.join
    end
    return out
  end
  
end

module SQLite3
  
  class Database
    
    def create_table (table, data, names = nil)
      ncols = data.rank == 1 ? 1 : data.dim1
      if names
        varlist = names.map{|s| s.to_s }
      elsif data.respond_to?(:names)
        varlist = data.names
      else
        varlist = []
        ncols.times do |i|
          varlist << "col#{i}"
        end
      end
      execute %{create table #{table} (#{varlist.join(",")})}
      insert(table, data)
    end
    
    def insert (table, data)
      table_info = execute %{
        pragma table_info(#{table}) 
      }  
      if table_info.empty?
        raise "#{table} is empty table"
      end
      qstns = (["?"]*table_info.size).join(",")
      self.transaction {
        stmt = prepare %{ 
          insert or replace into #{table} values (#{qstns}) 
        }
        data.to_a.each do |row|
          stmt.execute *row
        end
        stmt.close      
      }
    end

    def schema (table = nil)
      if table
        return get_first_value %{
          select sql from sqlite_master where type in ('table', 'view', 'index') and name = "#{table}"
        }
      else
        return execute(%{
          select sql from sqlite_master where type in ('table', 'view', 'index')
        }).map{|v| v[0]}
      end
    end

    # insert
    def import_table (dbfile, src_table, dst_table = nil)
      dst_table ||= src_table
      db = "db#{Thread.current.object_id}"
      execute %{
        attach database "#{dbfile}" as #{db};
      }
      sql = get_first_value %{
        select sql from #{db}.sqlite_master where type = 'table' and name = "#{src_table}"
      }
      sql.sub!(/create\s+table\s(.+?)\s/i, "create table if not exists #{dst_table}")
      execute sql
      execute %{
        insert into #{dst_table} select * from #{db}.#{src_table};
      }
      indeces = execute %{
        select sql from #{db}.sqlite_master where type = 'index' and tbl_name = "#{src_table}"        
      } 
      indeces.each do |row|
        sql = row[0]
        unless sql
          break
        end
        sql.sub!(/create\s+index/i, "create index if not exists")
        sql.sub!(/on\s+#{src_table}\(/i, "on #{dst_table}(")
        execute sql
      end
      execute %{
        detach database #{db};
      }
    end
    
  end
  
end



