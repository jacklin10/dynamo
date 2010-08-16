class DynamoField < ActiveRecord::Base
  # Associations
  has_many :dynamo_field_values, :dependent => :destroy
end