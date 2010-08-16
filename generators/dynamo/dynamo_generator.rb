class DynamoGenerator < Rails::Generator::NamedBase
  
  # When you run ./script/generate dynamo <anything> this will run.
  def manifest
    record do |m|
      # This stuff was in here by default.
      # m.directory "lib"
      # m.template 'README', "README"
      m.migration_template 'migration.rb', 'db/migrate' 
    end
  end
  
  def file_name
    # Name of the migration file that will be generated.  As in: 001_dynamo_migration.rb
    "dynamo_migration"
  end
  
end