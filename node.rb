#
# Represents a "Node-path" item
#

require 'item'

class ItemIsNotANode < Exception
end

class Node < Item
  attr_reader :path, :kind, :action
  #
  # Initialize from Dumpfile or YAML (Hash)
  #
  # Hash example:   {"order"=>[["Revision-number", 3984], ["Prop-content-length", 140], ["Content-length", 140]], "cpos"=>68, "pos"=>336443341,
  #
  def initialize input
    super input
    unless @type == "Node-path"
      input.pos = @pos if input.is_a? Dumpfile
      raise ItemIsNotANode.new(@type)
    end
    @path = @value
    kind = self["Node-kind"]
    @kind = kind.to_sym if kind
    action = self["Node-action"]
    @action = action.to_sym if action
  end

  def action= a
    @item['Node-action'] = a.to_s
    @action = a.to_sym
  end

  def make_relevant!
    @is_relevant = true
  end

  def to_s
    "<#{@action},#{@kind}> #{@path}"
  end
end

# A faked node, not existing in dumpfile
class FakeNode
  attr_reader :path, :kind, :action
  def initialize kind, action, path
    @kind = kind
    @action = action
    @path = path
  end
  
  def copy_to dump, file
    file.puts "Node-path: #{@path}"
    file.puts "Node-kind: #{@kind}"
    file.puts "Node-action: #{@action}"
    file.puts "Prop-content-length: 10"
    file.puts "Content-length: 10"
    file.puts
    file.puts "PROPS-END"
  end
  def to_s
    "<#{@action},#{@kind}> #{@path}"
  end
end
