# list-subdirs
# List all possible toplevel subdirs (== modules) in a SVN dump file
#
# * Assumption
# /trunk/<subdir>
# /branches/<branch>/<subdir>
# 
#
# * Syntax of a SVN dump file
#
# 1. Items:
#    Set of key/value pair lines
#    Set ends with empty line
#
#   <key>: <value>\n
#   <key1>: <value>\n
#   ...
#   \n
#   <data>
#   \n
#
# <data> is optional, e.g. a file/dir removal has no data
#
#
# If _last_ <keyX> == "Content-length", gives size of <data>
#
# 2. Initial <key> is either "Revision-number" (revision) or "Node-path" (node)
#
# 3. revisions have nodes
#

$debug = false

def usage why=nil
  STDERR.puts "***Err: #{why}" if why
  STDERR.puts "Usage: list-subdirs <dumpfile>"
  exit 1
end

#
# Accessing the svn dumpfile
#

class Dumpfile
  attr_reader :pos_of_line

  def initialize filename
    @filename = filename
    @dump = File.open(filename, "r")
    @line = nil
  end

  def eof?
    @dump.eof?
  end

  def gets
    @pos_of_line = @dump.pos
    return nil if @dump.eof?
    @line = @dump.gets.chomp
    @line
  end
  
  def skip bytes
    @dump.pos = @dump.pos + bytes
  end

  def goto pos
    @dump.pos = pos
  end

  def current
    @dump.pos
  end
  
  def copy_to from, size, file
    return unless size > 0
    old = @dump.pos
    # Ruby 1.9: IO.copy_stream(@dump, file, size, from)
    @dump.pos = from
    buf = @dump.read size
    file.write buf
    file.flush
    @dump.pos = old
  end
end


#
# Read generic item
#

class Item
  attr_reader :pos, :content_pos, :type, :value, :size, :content_size

  def initialize dump
    
    return if dump.eof?
    @dump = dump
    @header = {}
    @order = []
    @type = nil
    @changed = false

    # read header
    while (line = dump.gets)
      break if line.nil? # EOF
      if line.empty?
	if @type # end of header
	  break
	else
	  next # skip empty lines before type
	end
      end
      key,value = line.split ":"
      if value.nil?
	STDERR.puts "Bad line '#{line}' at %08x" % dump.pos_of_line
      end
      value.strip!
      @order << key
      @header[key] = value
      unless @type
	@pos = dump.pos_of_line
        @type, @value = key,value
      end
    end
    @pos ||= dump.pos_of_line
    cl = @header["Content-length"]
    @content_size = cl ? cl.to_i : 0
    @content_pos = dump.current
    @size = @content_pos + @content_size - @pos
  end

  def [] key
    @header[key]
  end

  def []= key, value
    @header[key] = value
    @changed = true
  end

  #
  def copy_to file
    if @changed
      @order.each do |key|
	value = @header[key]
	file.puts "#{key}: #{value}"
      end
      file.puts
      @dump.copy_to @content_pos, @content_size, file
    else
      @dump.copy_to @pos, @size, file
    end
  end

  def to_s
    "Item #{@type} @ %08x\n" % @pos
  end
end


#
# Represents a "Node-path" item
#

class Node
  attr_reader :path, :kind, :action
  def initialize dump, item
    @item= item
    @path = item.value
    kind = item["Node-kind"]
    @kind = kind.to_sym if kind
    action = item["Node-action"]
    @action = action.to_sym if action
    dump.skip item.content_size
  end

  def [] key
    @item[key]
  end

  def []= key, value
    @item[key] = value
  end

  def copy_to file
    @item.copy_to file
  end

  def to_s
    "<#{@action},#{@kind}> #{@path}"
  end
end

#
# Represents a "Revision-number" item
#

class Revision
  attr_reader :num, :newnum, :nodes, :is_relevant
  @@outnum = nil
  def initialize dump, item
    @item = item
    @num = item.value.to_i
    @nodes = []
    @newnum = -1
    @pos = dump.current
    @is_relevant = false
    unless @@outnum
      @@outnum = 0
      # pre-build relevant matches
      @@regexp_trunk_dir = Regexp.new("trunk/([^/]+)$")
      @@regexp_branches_top = Regexp.new("branches/([^/]+)$")
      @@regexp_branches_dir = Regexp.new("branches/([^/]+)/([^/]+)$")
      @@regexp_tags_top = Regexp.new("tags/([^/]+)$")
      @@regexp_tags_dir = Regexp.new("tags/([^/]+)/([^/]+)$")
    end
    dump.skip item.content_size
  end
  
  def to_s
#    s = @nodes.map{ |x| x.to_s }.join("\n\t")
    "Rev #{@newnum}<#{@num}> - #{@nodes.size} nodes, @ %08x" % @item.pos
  end
  
  # process node, returns subdir
  def process_node node
    
    # collect toplevel creators

    if node.kind == :dir && node.action == :add
      # find toplevel dir creators
      case node.path
      when @@regexp_branches_top, @@regexp_tags_top
      # can show branches and tags here
      when @@regexp_trunk_dir, @@regexp_branches_dir
	return $2 ? $2 : $1
      end

    end

  end # def process

end # class


###################
# Main


# get arguments

dumpfile = ARGV.shift
if dumpfile == "--debug"
  $debug = true
  dumpfile = ARGV.shift
end

usage unless dumpfile

STDERR.puts "Debug ON" if $debug

# open .dump file

dump = Dumpfile.new dumpfile

# check dump header and write to outfile

format = Item.new dump

usage "Missing dump-format-version" unless format.type == "SVN-fs-dump-format-version"
usage "Wrong dump format version '#{format.value}'" unless format.value == "2"

uuid = Item.new dump

unless uuid.type == "UUID"
  usage "Missig UUID"
end

# parse dump file and collect subdirs

subdirs = {}
rev = lastrev = nil
num = 0
loop do
  item = Item.new dump
  break unless item.pos # EOF
  case item.type
  when "Revision-number"
    # start new rev
    rev = Revision.new(dump, item)
    STDERR.write "#{rev.num}\r" if rev.num % 1000 == 0
    # consistency check - revision numbers must be consecutive
    unless rev.num == num
      STDERR.puts "Have rev #{rev.num}, expecting rev #{num}"
      exit 1
    end
    num += 1
  when "Node-path"
    # process node
    subdir = rev.process_node(Node.new(dump, item))
    subdirs[subdir] ||= true if subdir
  when nil
    break # EOF
  else
    STDERR.puts "Unknown type #{item.type} at %08x" % item.pos
  end
end

sortable = []
subdirs.each_key do |subdir|
  sortable << subdir
end

sortable.sort.each do |subdir|
  puts subdir
end

