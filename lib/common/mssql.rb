# Module for writing MSSQL queries
module MSSQL
    extend self

    def data_replace_script(client, to_export, db_name)
        script = ["USE #{db_name}"]
    
        to_export.each do |table|
            script << "DELETE FROM #{table}"
        end
    
        # Add all data
        to_export.each do |table|
            converted_cols = []
            table_cols_a = []
            table_cols_b = []
            client.execute("USE #{db_name} SELECT COLUMN_NAME, DATA_TYPE FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = '#{table}'").each do |row|
                if row['DATA_TYPE'] == 'image'
                    converted_cols << row['COLUMN_NAME']
                    table_cols_a << "cast('' as xml).value('xs:base64Binary(sql:column(\"#{row['COLUMN_NAME']}\"))', 'varchar(max)') as #{row['COLUMN_NAME']}"
                    table_cols_b << "cast(#{row['COLUMN_NAME']} as varbinary(max)) as #{row['COLUMN_NAME']}"
                else
                    table_cols_a << row['COLUMN_NAME']
                    table_cols_b << row['COLUMN_NAME']
                end
            end
            table_cols_a_str = table_cols_a.join(', ')
            table_cols_b_str = table_cols_b.join(', ')
            query = "USE #{db_name} SELECT #{table_cols_a_str} FROM #{table}"
            unless converted_cols.empty?
                query = "USE #{db_name} SELECT #{table_cols_a_str} FROM (SELECT #{table_cols_b_str} FROM #{table}) as #{table}"
            end
            client.execute("SET QUOTED_IDENTIFIER ON SET ANSI_NULLS ON SET ANSI_PADDING ON SET ANSI_WARNINGS ON SET CONCAT_NULL_YIELDS_NULL ON SET NUMERIC_ROUNDABORT OFF SET ARITHABORT ON").do
            client.execute("SET TEXTSIZE 2147483647").do
            client.execute(query).each do |row|
                vals = row.map do |k, v|
                    if converted_cols.include?(k.to_s) && !v.nil? && v != ''
                        "cast('#{v}' as xml).value('.','varbinary(max)')"
                    else
                        "'#{v.to_s.gsub("'", "''")}'"
                    end
                end
                script << "INSERT INTO #{table} VALUES (#{vals.join(', ')})"
            end
        end
        script.join("\n")
    end
end