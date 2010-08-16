# This is the migration file for dynamo.  To generate this file in your app run:
# ./script/generate dynamo <option> and it will create the migration for you, and move it to your app's migrate directory
class DynamoMigration < ActiveRecord::Migration
  def self.up
    create_table :dynamo_field do |t|
      t.column :model, :string
      t.column :field_name, :string
      t.column :field_type, :string
      t.timestamps
    end
    
    create_table :dynamo_field_value do |t|
      t.column :dynamo_field_id, :integer
      t.column :val_string, :string
      t.column :val_int, :integer
      t.column :val_float, :float
      t.timestamps
    end
    
    add_index :dynamo_field_value, :dynamo_field_id
  end
  
  def self.down
    drop_table :dynamo_field
    drop_table :dynamo_field_value
  end
end