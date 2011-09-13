# filter-revs
# filter interesting revisions

#
# Syntax of a SVN dump file
#
# 1. Set of key/value pair lines
#    Set ends with empty line
#
# <key>: <value>\n
# <key1>: <value>\n
# ...
# \n
# <data>
# \n
#
# If _last_ <keyX> == "Content-length", gives size of <data>
#
# 2. Initial <key> is either "Revision-number" or "Node-path"
#

def usage why=nil
  STDERR.puts "***Err: #{why}" if why
  STDERR.puts "Usage: filter-revs <dumpfile> [<subdir>]"
  exit 1
end

class Node
  attr_reader :path, :kind, :action, :revnum
  def initialize revnum, path, kind, action
    @revnum = revnum
    @path = path 
    @kind = kind.to_sym if kind
    @action = action.to_sym
    @matches = (@action == :add &&
		@kind == :dir &&
		(@path == "trunk" || @path == "branches" || @path == "tags"))
  end
  def matches? filter
    return true if @matches
    if @path =~ Regexp.new("trunk/#{filter}") ||
       @path =~ Regexp.new("branches/[^/]+/#{filter}") ||
       @path =~ Regexp.new("tags/[^/]+/#{filter}")
     true
   else
     false
   end
  end
  def to_s
    "<#{@action},#{@kind}> #{@path}"
  end
end

class Revision
  attr_reader :num, :branch_creations, :nodes, :start
  def initialize dump
    @start = dump.start
    @num = dump.find("Revision-number").to_i
    @nodes = []
    @branch_creations = []
    read_nodes dump
  end
  
  def read_nodes dump
    loop do
      @next = dump.current
      k, v = dump.find
      raise EOFError if k.nil?
#      puts "\t#{k}: #{v}"
      case k
      when "Content-length"
	skip = dump.current + v.to_i
#	puts "content-length #{v} @ %08x -> %08x" % [ dump.current, skip ]
	dump.skip v.to_i
      when "Node-path"
	read_node dump, v, dump.start
      when "Revision-number"
	dump.goto @next
	break
      end
    end
  end
  
  def read_node dump, path, pos
    # find next key-value pair, might be Node-action or Node-kind
    # note: action 'delete' does not have 'kind'
    key, value = dump.find 
    case key
    when "Node-kind"
      kind = value
      # action always follows kind
      action = dump.find("Node-action")
    when "Node-action"
      kind = nil
      action = value
      # action without previous kind must be 'delete'
      raise unless action == "delete"
    end
    node = Node.new(@num, pos, path, kind, action)
    @nodes << node
    
    # remember nodes creating a new branch
    if node.action == :add &&
      node.kind == :dir
      if node.path =~ Regexp.new("^branches/([^/]+)$")
	# STDERR.puts "rev #{@num} creates branch #{node}"
	@branch_creations << node
      end
    end
  end
  
  def affects? filter
    @nodes.each do |node|
      return true if node.matches? filter
    end
    false
  end
  def to_s
    s = @nodes.map{ |x| x.to_s }.join("\n\t")
    "Rev #{@num}: #{s}"
  end
end


#
# Accessing the svn dumpfile
#

class Dumpfile
  attr_reader :start

  def initialize filename
    @filename = filename
    @dump = File.open(filename, "r")
    @line = nil
  end

  # find next key
  # if key == nil, will find next key
  # else will find given key
  #
  def find key=nil
    @start = dump.pos
    while (@line = @dump.gets)
      pos = dump.pos
      break unless @line
      @line.chomp!
      if @line.empty?
	@start = pos
	next
      end
      if key
	unless @line.start_with? key
	  @start = pos
	  next
	end
      end
      @key,@value = @line.split ":"
      if @value.nil?
        @start = pos
	next
      end
      if key
	unless key == @key
	  @start = pos
	  next
	end
	return @value.strip!
      end
      return @key, @value.strip!
    end
    nil
  end

  def gets
    @start = dump.pos
    @line = @dump.gets.chomp
  end
  
  def skip bytes
    @dump.pos = @dump.pos + bytes
  end

  def goto pos
    @dump.pos = pos
  end

  def nextrev
    begin
      Revision.new self
    rescue EOFError
      nil
    end
  end
  
  def current
    @dump.pos
  end
end

dumpfile = ARGV.shift
filter = ARGV.shift

usage unless dumpfile

dump = Dumpfile.new dumpfile
uuid = nil

usage "Wrong dump format version '#{v}'" unless dump.find("SVN-fs-dump-format-version") == "2"
uuid = dump.find "UUID"
num = 0
branches = {}
revisions = []
while (rev = dump.nextrev)
#  puts "Rev #{rev.num} @ %08x" % dump.current
  break unless rev
  if (num != rev.num)
    STDERR.puts "nextrev is #{rev.num}, expected #{num}"
    exit 1
  end
  num += 1
  rev.branch_creations.each do |node|
    path = node.path.split "/"
    branch = path[1]
    branches[branch] ||= node.revnum
  end
  if rev.affects? filter
    revisions << rev.num    
    rev.nodes.each do |node|
      next unless node.path.start_with? "branches/"
      path = node.path.split "/"
      revnum = branches[path[1]]
      if revnum
	revisions << revnum
      else
	STDERR.puts "Can't find origin of #{node.path} (#{path[1]})"
      end
    end
  end
end

puts revisions.sort.uniq.join("\n")
