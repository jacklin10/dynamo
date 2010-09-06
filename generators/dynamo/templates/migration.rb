# This is the migration file for dynamo. To generate this file in your app run:
# ./script/generate dynamo <option> and it will create the migration for you, and move it to your app's migrate directory
class DynamoMigration < ActiveRecord::Migration
  def self.up
    create_table :dynamo_fields do |t|
      t.column :model, :string
      t.column :field_name, :string
      t.column :field_type, :string
      t.timestamps
    end

    add_index :dynamo_fields, :model
    
    create_table :dynamo_field_values do |t|
      t.column :dynamo_field_id, :integer
      t.column :model_id, :integer
      t.column :val_string, :string
      t.column :val_int, :integer
      t.column :val_float, :float
      t.timestamps
    end
    
    add_index :dynamo_field_values, :dynamo_field_id
  end
  
  def self.down
    drop_table :dynamo_fields
    drop_table :dynamo_field_values
  end
end