#
# Represents a "Revision-number" item
#

require 'node'

class ItemIsNotARevision < Exception
end

class Revision < Item
  attr_reader :num, :newnum, :nodes

private
  #
  # Init Revision from Dumpfile
  # input: Dumpfile
  # 
  def init_rev_from_dumpfile input
    unless @type == "Revision-number"
      input.pos = @pos
      raise EOFError if @type.nil?
      STDERR.puts "Revision.init_rev_from_dumpfile read '#{@type}'"
      raise ItemIsNotARevision.new(@type)
    end
    @num = @value.to_i
    @nodes = []
    @newnum = -1
    
    loop do
      begin
	@nodes << Node.new(input)
      rescue EOFError
	break
      rescue ItemIsNotANode
	break
      end
    end
  end

  #
  # Init Revision from YAML
  # input: map
  #   {"order"=>[["Revision-number", 3984], ["Prop-content-length", 140], ["Content-length", 140]], "cpos"=>68, "pos"=>336443341,
  #    "nodes"=>[
  #      { "order" =>[ ["Node-path", "tags/branch-Code-11-SP2-2_17_86"],
  #		       ["Node-kind", "dir"],
  #		       ["Node-action", "add"],
  #		       ["Prop-content-length", 10],
  #		       ["Content-length", 10]
  #		     ],
  #		     "cpos"=>119,
  #		     "pos"=>336443550
  #	 }
  #    ]
  #  }
  #
  def init_rev_from_yaml input
    @num = @value
    nodes = input["nodes"]
    if nodes
      nodes.map! { |n| Node.new(n) }
      @nodes = nodes
    else
      @nodes = []
    end
  end

  #
  # Make a revision's node relevant
  # this also makes the whole revision relevant
  # and remember if the node has a Node-copyfrom-rev we have to rewrite later
  #
  def make_node_relevant node
    node.make_relevant!
    @is_relevant ||= true
    @have_copyfrom_node ||= node['Node-copyfrom-rev']
  end

public
  #
  # Initialize Revision from Dumpfile or YAML (Hash)
  #

  def initialize input
    super input
    if input.is_a? Dumpfile
      init_rev_from_dumpfile input
    else
      init_rev_from_yaml input
    end
    @have_copyfrom_node = false
  end

  def << node
    @nodes << node
  end

  def has_copyfrom_nodes?
    @have_copyfrom_node
  end

  # make node (matching path) relevant
  #
  # return node if relevant match found
  #
  def make_relevant! node_or_path = nil
    case node_or_path
    when Node
      make_node_relevant node_or_path
      return node_or_path
    when String
      @nodes.each do |node|
	if node.path == node_or_path
	  make_node_relevant node
	  return node
	end
      end
    when nil
      @is_relevant = true
    else
      raise "Make what relevant ? #{node_or_path.class}"
    end
    nil
  end

  def newnum= num
    @newnum = num
    self[@type] = @newnum
  end

  # copy revision item to file
  #  Attn: this only copies the revision item itself, _not_ the nodes
  #
  def copy_to input, output
    super input, output
    output.puts
  end

  def to_s
#    s = @nodes.map{ |x| x.to_s }.join("\n\t")
    "Rev #{@newnum}<#{@num}> - #{@nodes.size} nodes, @ %08x" % @pos
  end
  

end # class
