module RR
  module ConnectionExtenders
    module IBM_DBExtender
      RR::ConnectionExtenders.register :ibm_db => self
      
       # *** Monkey patch***
        def add_limit_offset!(query, options)
          "#{query} fetch first #{options[:limit]} rows only"
        end

        def savepoint(name)
          execute("savepoint #{name} on rollback retain cursors")
        end

        def primary_key_names(table)
          [primary_key(table)]
        end

        def reachable?
          select_one("select 1+1 as x from sysibm.sysdummy1")['x'].to_i == 2
        end

        def quote(value, column = nil) # :nodoc:        
          if column && column.type == :primary_key
            return value.to_s
          end
          if column && (column.type == :decimal || column.type == :integer) && value
            return value.to_s
          end
          case value
          when String
            if column && column.type == :binary
              if value.length==0
                'cast(null as blob)'
              else
                "0x#{value.unpack('H*')[0]}"
              end
            else
              "'#{quote_string(value)}'"
            end
          else super
          end
        end
        
        # Returns for each given table, which other tables it references via
        # foreign key constraints.
        # * tables: an array of table names
        # * returns: a hash with
        #   * key: name of the referencing table
        #   * value: an array of names of referenced tables
        def referenced_tables(tables)
          result = {}
          tables.each do |table|
            result[table] = []
            self.select_all("select reftabname from syscat.references where tabname = '#{table.upcase}'").each do |row|
              result[table] << row['reftabname'].downcase
            end
          end
          result
        end

        def quote_string(string)
          string.gsub(/'/, "''")
        end
    end
  end
end

