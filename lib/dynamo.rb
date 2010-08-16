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
        # alias_method_chain:
        # http://weblog.rubyonrails.org/2006/4/26/new-in-rails-module-alias_method_chain
        # Basically the 'normal' method_missing is now called :method_missing_without_dynamo
        # and the dynamo overridden version is called :method_missing_with_dynamo
        # Now when we have an attribute that is part of the object in a normal rails way we just use the 
        # 'without' method, but for dynamic attributes we need to do some extra stuff so we use the 'with' method.
        
        # Make sure the methods haven't been built already
        unless method_defined? :method_missing_without_dynamo
          # We don't save the dynamo_field_value until after the model is saved. This is because we need the db id and that doesn't exist
          # until after you save to the db.
          after_save :delay_save
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
      
      clear_cache
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

      clear_cache
    end
    
    # Returns array of all field names ( not DynamoField objects) for this model.
    # example:
    #  Supplier.dynamo_fields
    def dynamo_fields
      # Can't really cache this because if you have multi db's per customer and you connect to 
      # a different customer then it will have the fields for the previous object instead.
      DynamoField.find(:all, :conditions=>['model = ?', self.to_s]).map(&:field_name)
    end
    
    # Deletes the dynamo_fields cache key so the next time you need to read the fields
    # they will be retrieved from the db.
    # Use when you add / remove a new dynamo field
    def clear_cache
      Rails.cache.delete('dynamo_fields')
    end
    
  end # ClassMethods
  
  module InstanceMethods
    
    # Instance level cache of the dynamo fields for this model.
    # When you output a dynamo field or value it several calls to is_dynamo_field.
    # Now that the fields are cached it saves all those db queries.
    def cached_dynamo_fields
      return Rails.cache.read("dynamo_fields") unless Rails.cache.read("dynamo_fields").nil?
      Rails.cache.write("dynamo_fields", DynamoField.find(:all, :conditions=>['model = ?', self.class.to_s]).map(&:field_name))
      Rails.cache.read("dynamo_fields")
    end
    
    # Returns true if the given field name is a dynamic field for this model
    # example:
    #  Supplier.is_dynamo_field?(:some_field)
    def is_dynamo_field?(field_name)
      cached_dynamo_fields.include? field_name
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
        # Finds the DynamoField for the given field and then returns the value for it.
        df = DynamoField.find_by_field_name(field_name)
        # The only tricky part is that it looks at the type for the DynamoField to determine which column
        # in DynamoFieldValues to read from.  ( .send(df.field_type )
        # Note that it returns an array of values.  This is for when you have a multi select ( not implemented yet )
        vals = (df.dynamo_field_values.empty?) ? '' : df.dynamo_field_values.detect{|i| !i.send(df.field_type).nil? && i.model_id == self.id }
        
        if vals.blank?
          return nil
        end
        
        return vals.send(df.field_type)
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
        @dynamo_field = DynamoField.find_by_field_name(field_name)
        @all_fields_and_values << {:field => @dynamo_field.id, :field_type => @dynamo_field.field_type, :val=>value}
        @dynamo_field_value = value
      end
      # If its a 'normal' attribute let rails write it in the usual way.
      write_attribute_without_dynamo(field_name, value)
    end
    
    # We need the id of this model to link it to the value.  That id doesn't exist until
    # after it has been saved.  We use the after save callback to update the field_value to make the link.
    def delay_save
      # The all_fields_and_values array is populated in the write_attribute_with_dynamo method above.
      @all_fields_and_values.each do |fv|
        dfv = DynamoFieldValue.find(:first, :conditions =>["model_id = ? AND dynamo_field_id = ?", self.id, fv[:field]]) || DynamoFieldValue.new(:dynamo_field_id => fv[:field])
        dfv.send("#{fv[:field_type]}=", fv[:val])
        dfv.model_id = self.id
        dfv.save!
      end unless @all_fields_and_values.nil? # If no dynamo attributes exist then the array will be nil
      
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
