module DynamoHelper
  
  # Helper that returns an html table with the dynamo attributes plugged in.
  # There aren't too many formatting options available using this helper.  If you need
  # the dynamo attributes to fit in your customer view see the 'fields' helper.
  #  Params:  form_helper - Needed to build the text_field
  #           text_field_size - the size of the text field ( note all will have the same size )
  #  Example:
  #  <%= @my_dynamo_model.fields_table(f) %>
  # * my_dynamo_model is a model that you have applied dynamo to.   
  #  This will yield something like:
  #  <table><tr><td>my dynamo attribute</td><td><input type='text' name='my_dynamo_model[my dynamo attribute]' size='15' value='hello'></td></tr></table>
  def dynamo_fields_p(form_helper, text_field_size=30)
    html=[]
    self.class.dynamo_fields.each do |dynamo_field|
      html << '<p>'
      html <<  dynamo_field << '<br />'
      html <<  form_helper.text_field(dynamo_field, :size=>text_field_size)
      html << '</p>'
    end
    return html
  end
  
  # Helper that returns the names of the dynamo fields.  
  # You have to do a little more on the view side for this one but it gives you greater ability to customize how things will look.
  #  Example:
  #    <%  @supplier.fields do |field_name| %>
  #      <tr>
  #        <td><%= field_name %></td>
  #        <td><%= f.text_field field_name %></td>
  #      </tr>
  #    <%  end %>
  # 
  #  Now we have full control over the text_field tag and the formatting of the fields.  
  #  If your view requires the attributes to be formatted in a specific way to fit in with the other elements of the page
  #  you'll want to use this one, or write a new one that follows your style.
  def dynamo_fields
    self.class.dynamo_fields.each do |dynamo_field|
        yield dynamo_field
    end
  end
        
end # DynamoHelper
