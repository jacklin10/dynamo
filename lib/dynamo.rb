module Dynamo
  
  include DynamoHelper
  
  # map types to those contained in the db. Avoids any name collisions using names like string and float.
  VALID_FIELD_TYPES = {:Text => 'val_string', :Number=>'val_int', :Decimal=>'val_float'}
  
  # Ensures your ClassMethods are available to the Dynamo module
  def self.included(base)
    base.extend ClassMethods
  end
  
  module ClassMethods
    
    def has_dynamic_attributes(*attrs)
      
      include InstanceMethods
      
      # Create access/mutator for this new field
      self.class_eval do
        
        # Override rails method to add the dynamo columns for the class.
        def self.column_names
          @column_names ||= columns.map { |column| column.name }
          # Add the dynamo column names to the list.
          @column_names + self.dynamo_fields
        end
        
        # alias_method_chain:
        # http://weblog.rubyonrails.org/2006/4/26/new-in-rails-module-alias_method_chain
        # Basically the 'normal' method_missing is now called :method_missing_without_dynamo
        # and the dynamo overridden version is called :method_missing_with_dynamo
        # Now when we have an attribute that is part of the object in a normal rails way we just use the
        # 'without' method, but for dynamic attributes we need to do some extra stuff so we use the 'with' method.
        attr_accessor :dynamo_cache
        attr_accessor :dynamo_field_value_cache
        
        # Make sure the methods haven't been built already
        unless method_defined? :method_missing_without_dynamo
          # We don't save the dynamo_field_value until after the model is saved. This is because we need the db id and that doesn't exist
          # until after you save to the db.
          after_save :delay_save
          after_destroy :cleanup_after_destroy
          alias_method_chain :method_missing,  :dynamo
          private
          alias_method_chain :read_attribute,  :dynamo
          alias_method_chain :write_attribute, :dynamo
        end
      end
      
    end
    
    # Call with Model.add_dynamo()
    # This will add the field to the database, and if a field_value is passed in then it will be stored also
    # params:
    #   field_name - name of the field to remove.  Accepts a symbol or a string.
    #   field_type - type of field.  @see VALID_FIELD_TYPES.  Accepts symbol or string
    # examples:
    #  Supplier.add_dynamo_field(:zzzz)
    #  Supplier.add_dynamo_field('my_field', :string)
    def add_dynamo_field(field_name, field_type=:string)
      field_name = field_name.to_s
      field_type = field_type.to_s
      logger.debug "Dynamo: add_dynamo field  Name: #{field_name} FieldType: #{field_type} "
      
      # Ensure a field with this name doesn't already exist for this particular class
      raise ArgumentError, "The column #{field_name} already exists for the model #{self.to_s}" if DynamoField.find(:all, :conditions=>['model = ? AND field_name = ?', self.to_s, field_name], :limit=>1).size > 0
      
      # Ensure a valid type is given
      raise ArgumentError, "Invalid field type given: #{field_type}. Valid types are: #{VALID_FIELD_TYPES.keys.join(',')}" unless VALID_FIELD_TYPES.has_key? field_type.to_sym
      
      # Create and save this new dynamic field.
      DynamoField.new(:model=>self.to_s, :field_name=>field_name, :field_type=>VALID_FIELD_TYPES[field_type.to_sym]).save!
    end
    
    # Remove the given field from the DynamoField model.
    # params:
    #   field_name - name of the field to remove.  Accepts a symbol or a string.
    # examples:
    #  Supplier.remove_dynamo_field(:zzzz)
    #  Supplier.remove_dynamo_field('zzzz')
    def remove_dynamo_field(field_name)
      field_name = field_name.to_s
      logger.debug "Dynamo: remove_dynamo field  Name: #{field_name}"
      # NOTE: Delete doesn't fire callbacks like before_destroy, after_destroy, but its faster.
      logger.warn "Attempted to delete non-existing field: #{self.to_s}:#{field_name}" if DynamoField.delete_all(:field_name=>field_name) == 0
    end
    
    # List all the dynamo fields available to this class.
    # example:
    #  Supplier.dynamo_fields
    def dynamo_fields
      DynamoField.find(:all, :conditions=>['model = ?', self.to_s]).map(&:field_name)
    end
    
  end # ClassMethods
  
  module InstanceMethods
    
    # Instance level cache of the dynamo fields for this model.
    def cached_dynamo_fields
      return self.dynamo_cache unless self.dynamo_cache.nil?
      self.dynamo_cache = DynamoField.find(:all, :conditions=>['model = ?', self.class.to_s])
    end
    
    # Stores a cache of the field values for this model.
    def cached_dynamo_field_values
      # We only want to load the field_values available for this model 1 time otherwise it'll query
      # for each value read from the dynamo model. This was really slowing things down like exporting a model
      # to xls or something where you are reading 100's of dynamo model's and values all at one time.
      self.dynamo_field_value_cache ||= DynamoFieldValue.find_all_by_model_id(self.id)
    end
    
    # Returns true if the given field name is a dynamic field for this model
    # example:
    #  Supplier.is_dynamo_field?(:some_field)
    def is_dynamo_field?(field_name)
      # If result of this find is not nil it means the field does exist so return true because it is a dynamo field
       (cached_dynamo_fields.detect{|dynamo_field| dynamo_field.field_name == field_name}.nil?) ? false : true
    end
    
    # Helper method to get a dynamo_field object from the cache by its field_name
    def cached_dynamo_field_by_name(field_name)
      cached_dynamo_fields.detect{|df| df.field_name == field_name}
    end
    
    private
    
    # Override of the rails method_missing method
    # When you attempt to access a dynamo field there are no methods available so
    # we will end up in here.  If the desired field is found to be a dynamo field then
    # we will read or write that attribute using overrides of the rails read_attribute / write_attribute methods.
    # params:
    #  You don't really call this method directly.
    # example:
    #  You'll end up in here if you do something like:
    #  MyModel.some_non_existant_method
    def method_missing_with_dynamo(method_id, *args, &block)
      begin
        # Try the super method_missing. If the method doesn't exist then try
        # to see if its a dynamo attributes they are trying to access.
        method_missing_without_dynamo(method_id, *args, &block)
      rescue NoMethodError => e
        # If the method name ends with an = then its a setter. We take off the = so we can check if its a dynamo field.
        attr_name = method_id.to_s.sub(/\=$/, '')
        if is_dynamo_field?(attr_name)
          # If there's an = in there then someone's attempting to write.
          if method_id.to_s =~ /\=$/
            return write_attribute_with_dynamo(attr_name, args[0])
          else
            return read_attribute_with_dynamo(attr_name)
          end
        end
        # Looks like its a method rails nor dynamo understands. Error time!
        raise e
      end
    end
    
    # Override of the rails read_attribute method
    # If we detect a dynamo field we do a read from the dynamo tables, if not then we call the rails version of the method.
    def read_attribute_with_dynamo(field_name)
      field_name = field_name.to_s
      if is_dynamo_field?(field_name)
        
        # If the model's id is nil then we know there aren't going to be any values to read.
        # example: If this is a supplier model and we are creating a new supplier at this point its id is nil
        #          Because of this fact we know there are no dynamo_field_values associated with it so return.
        #  If we didn't return here then when checking for values we would create extra queries.
        #  Any time we do a df.dynamo_field_values we create overhead so we only want to do that when we have to.
        return if self.id == nil
        
        # We're doing a real read now so get the dynamo_field from the cache then query to get the correct value.
        dynamo_field = cached_dynamo_field_by_name(field_name)
        
        # Get all the dynamo field values for this model from the cache.
        dynamo_field_value = cached_dynamo_field_values.detect{|dyn_field_val| dyn_field_val.dynamo_field_id == dynamo_field.id && dyn_field_val.model_id == self.id }
        
        return nil if dynamo_field_value.blank?
        return dynamo_field_value.send(dynamo_field.field_type)
      end
      # If its a 'normal' attribute let rails handle it in its usual way
      read_attribute_without_dynamo(field_name)
    end
    
    # Override of the rails write_attribute method
    # If we detect a dynamo field we do a read from the dynamo tables, if not then we call the rails version of the method.
    def write_attribute_with_dynamo(field_name, value)
      if is_dynamo_field?(field_name)
        # Store these guys for now.  We don't actually save the field value until the model is saved ( i.e my_supplier.save ).
        # If we were to save the field_value now we wouldn't be able to know the id of the model to link this value to it.
        # @see delay_save
        @all_fields_and_values ||= []
        @all_fields_and_values << {:dynamo_field=>cached_dynamo_field_by_name(field_name), :value=>value}
      end
      # If its a 'normal' attribute let rails write it in the usual way.
      write_attribute_without_dynamo(field_name, value)
    end
    
    # Ensure the dynamo_field_values that are associated with this model
    # are removed after the model itself has been deleted
    def cleanup_after_destroy
      ActiveRecord::Base.connection.execute("DELETE FROM dynamo_field_values WHERE model_id = #{self.id}")
    end
    
    # Builds one section of a bulk insert statment. 
    # Returns a string like: ('val1', 'val2', 3)
    # So its meant to be plugged in to a block insert statment.
    def build_insert_stmt(dynamo_field_value)
      values = []
      insert_stmt_fields = DynamoFieldValue.column_names.reject{ |field| field == 'id'}
      insert_stmt_fields.each do |field_name|
        # We need to tinker with fields based on their type for sql syntax purposes
        temp_val = dynamo_field_value.send(field_name)
        temp_val = "'#{temp_val}'" if temp_val.class.to_s == "String" || temp_val.class.to_s == "ActiveSupport::TimeWithZone"
        temp_val = "NULL" if temp_val.nil?
        values << temp_val
      end
      "(#{values.join(',')})"
    end
    
    # We need the id of this model to link it to the value.  That id doesn't exist until
    # after it has been saved.  We use the after save callback to update the field_value to make the link.
    def delay_save
      
      return if @all_fields_and_values.nil?
      
      # If there is a dynamo_field_value for one of this model's fields then there will be for all.  Query for it here
      # and you'll only do it once, but move it into the loop and you'll count for each dynamo_field.
      first = @all_fields_and_values[0]
      count = DynamoFieldValue.count(:conditions=>"model_id = #{self.id} AND dynamo_field_id=#{first[:dynamo_field].id}")
      
      all_values = []
      @all_fields_and_values.each do |fv|
        # If count is 0 it means that no dynamo_field_values exist for this model so its brand new.
        if count == 0
            dfv = DynamoFieldValue.new(:dynamo_field_id=>fv[:dynamo_field].id, :model_id=>self.id, :created_at=>Time.now, :updated_at=>Time.now, "#{fv[:dynamo_field].field_type}".to_sym => fv[:value])
          all_values << build_insert_stmt(dfv)
        else
          # This is an existing set of values so we need to update.
          # Update is slower because we need to get the dynamo_field_values for this field so its extra queries
          dfv = fv[:dynamo_field].dynamo_field_values
          if dfv.blank?
            dfv = DynamoFieldValue.new(:dynamo_field_id=>fv[:dynamo_field].id, :model_id=>self.id, :created_at=>Time.now, :updated_at=>Time.now, "#{fv[:dynamo_field].field_type}".to_sym => fv[:value])
            all_values << build_insert_stmt(dfv)
            # If you don't clear the cache a second save on this instance won't see the newly created dynamo_field_value and it will insert it again.
            self.dynamo_cache=nil
          else
            # Find the dynamo_field_value we want to update.
            dfv = dfv.detect{|dyn_field_value| dyn_field_value.model_id == self.id}
            dfv.send("#{fv[:dynamo_field].field_type}=", fv[:value])
            dfv.save!
          end
        end
        
        # Reset this now that we have processed all the insert / updates needed.  If you don't 
        # a double call to save could produce unexpected results.
        @all_fields_and_values = nil
      end
      
      return if all_values.empty?
      
      # improving performance by doing bulk inserts. The more dynamic fields the model has the more benefit this has over single inserts.
      bulk_insert_stmt = "INSERT INTO `dynamo_field_values`(#{DynamoFieldValue.column_names.reject{ |field| field == 'id'}.join(',')}) VALUES #{all_values.join(',').gsub(/"NULL"/, 'NULL')}"
      ActiveRecord::Base.connection.execute(bulk_insert_stmt)
    end
    
    # This is overridden from ActiveRecord and the only change is commenting out the respond_to
    # It is called when you try to construct a class using dynamo as in Supplier.new :my_attribute => 'some_value'
    def attributes=(new_attributes, guard_protected_attributes = true)
      return if new_attributes.nil?
      attributes = new_attributes.dup
      attributes.stringify_keys!
      multi_parameter_attributes = []
      attributes = remove_attributes_protected_from_mass_assignment(attributes) if guard_protected_attributes
      
      attributes.each do |k, v|
        if k.include?("(")
          multi_parameter_attributes << [ k, v ]
        else
          # This will fail if we are adding dynamic attributes. In dynamo we'll let the method_missing pick
          # up when the attribute doesn't exist and we'll handle it from there.
          # respond_to?(:"#{k}=") ? send(:"#{k}=", v) : raise(UnknownAttributeError, "unknown attribute: #{k}")
          send(:"#{k}=", v)
        end
      end
      
      assign_multiparameter_attributes(multi_parameter_attributes)
    end
    
    # Override from Rails.  This ensures that when you do an:  some_instance.attributes
    # you'll get the dynamo attributes in the list.
    # Also means that instance.respond_to? :dynamo_attr will work!
    def attributes_from_column_definition
      # If there are dynamo fields put them in the list.
      unless self.class.dynamo_fields.empty?
        attributes = self.class.dynamo_fields.inject({}) do |attributes, column|
          attributes[column.to_s] = nil
          attributes
        end
      end
      # Add any dynamo attributes to 'normal' attributes
      self.class.columns.inject(attributes || {}) do |attributes, column|
        attributes[column.name] = column.default unless column.name == self.class.primary_key
        attributes
      end
    end
    
  end # end instance_methods
end # end Dynamo

# Important because any model you use this in will extend from activeRecord.
# This includes the Dynamo module into ActiveRecord
ActiveRecord::Base.send :include, Dynamo
