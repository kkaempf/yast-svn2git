# dump-splitter.rb
# Split SVN dump file according to subdirectory
#
# Written by Klaus Kämpf <kkaempf@suse.de>
# License: GPL v2 only
#
# = Version history =
#
# Version 3.0
# - handle branch points better 
# - do not read whole history but do a stream filtering
#   with a focus of rewriting branch points to relevant
#   ones
# - Problem: 'svn mv' from non-relevant revisions
#
# Version 2.0
# - more elaborate dump filter focussing on node touching
#   specific pathes
# - read all revisions, then filter relevant ones
# - Problem: branch points are hard to get right since they
#   might be in the past and evtl. pointing to an non-relevant
#   revision
#
# Version 1.0
# - simple extractor of relevant rev numbers to feed as
#   --revisions-file into svn-all-fast-export
# - Problem: Fails to handle branch points as they origin
#   from non-relevant revisions. Need to backtrack those.
#
# = Implementation =
#
# * Assumption
# /trunk/<subdir>
# /branches/<branch>/<subdir>
# /tags/<branch>_<tag>/<subdir>
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
  STDERR.puts "Usage: dump-splitter <dumpfile> <filter>"
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

  # Hash of <toplevel_dir> => [relevant revisions for subdir]
  @@last_relevant_for = {}
  
  # Map number of relevant revisions from old => new
  @@revision_number_mapping = {}
  
  # remember already created pathes as we process the revtree
  @@created_pathes = {}

  @@outnum = nil

  def initialize dump, item, filter
    @item = item
    @num = item.value.to_i
    @nodes = []
    @newnum = -1
    @pos = dump.current
    @is_relevant = false
    dump.skip item.content_size
    unless @@outnum
      @@outnum = 0
      # pre-build relevant matches
      @@regexp_trunk_dir = Regexp.new("trunk/#{filter}$")
      @@regexp_trunk_file = Regexp.new("trunk/#{filter}/.*$")
      @@regexp_branches_top = Regexp.new("branches/([^/]+)$")
      @@regexp_branches_dir = Regexp.new("branches/([^/]+)/#{filter}$")
      @@regexp_branches_file = Regexp.new("branches/([^/]+)/#{filter}/.*$")
      @@regexp_tags_top = Regexp.new("tags/([^/]+)$")
      @@regexp_tags_dir = Regexp.new("tags/([^/]+)/#{filter}$")
      @@regexp_tags_file = Regexp.new("tags/([^/]+)/#{filter}/.*$")
    end
  end
  
  def make_relevant!
    @is_relevant = true
  end

  def outnum
    @@outnum
  end

  def << node
    @nodes << node
  end

  # copy revision item to file
  #  Attn: this only copies the revision item itself, _not_ the nodes
  #
  def copy_to file
    file.puts "# Revision #{@@outnum}<#{@num}>" if $debug
    @newnum = @@outnum
    @@revision_number_mapping[@num] = @newnum
    @item[@item.type] = @newnum
    @@outnum += 1
    @item.copy_to file
    file.puts
  end

  def to_s
#    s = @nodes.map{ |x| x.to_s }.join("\n\t")
    "Rev #{@newnum}<#{@num}> - #{@nodes.size} nodes, @ %08x" % @item.pos
  end
  
  # find last relevant in path
  def find_and_write_last_relevant_for path, file, revnum = nil
    last_relevant = nil
    file.puts "# find_and_write_last_relevant_for #{path}" if $debug
    start_path = path
    loop do
      last_relevants = @@last_relevant_for[path]
      if last_relevants
	if revnum # search less-than-or-equal to this number
	  idx = last_relevants.size
	  while idx > 0
	    idx -= 1
	    rev = last_relevants[idx]
	    if rev.num <= revnum
	      last_relevant = rev
	      break
	    end
	  end
	else
	  last_relevant = last_relevants.last
	end
	file.puts "# '#{path}' - last_relevant -> #{last_relevant}" if $debug
	break if last_relevant && last_relevant != self
      end
      path = File.dirname(path)
      break if path == "."
    end
    if path == "."
      STDERR.puts "No last relevant for '#{start_path}' at #{self}"
      last_relevant = nil
      #	  @@last_relevant_for.each do |k,v|
      #	    STDERR.puts "'#{k}' -> #{v.num}"
      #	  end
    else
      # if not already written
      unless @@revision_number_mapping[last_relevant.num]
	# write out relevant rev
	last_relevant.make_relevant!
	last_relevant.process_and_write_to file
      end
    end

    return last_relevant
  end

  # process complete Revision according to filter
  def process_and_write_to file
    
    return unless @is_relevant	

    # svnadmin: Malformed dumpstream: Revision 0 must not contain node records
    #
    # so discard revision without nodes, _except_ for revision 0
    if @nodes.empty? && @num > 0
      return
    end

    file.puts "# process_and_write #{self}" if $debug

    @nodes.each do |node|
      
      next if node.action == :delete

      # check node.path and if we already have all parent dirs
      path = node.path
      if node.kind == :file
	path = File.dirname(path)
      elsif node.kind == :dir
	case node.path
	when "trunk", "branches", "tags"
	  next
	end
      end
      last_relevant = find_and_write_last_relevant_for path, file
      exit 1 unless last_relevant

      # check for Node-copyfrom-path and evtl. rewrite / backtrack

      path = node['Node-copyfrom-path']
      if path
	# backtrack, find last relevant revision for this path
	revnum = node['Node-copyfrom-rev'].to_i
	last_relevant = find_and_write_last_relevant_for path, file, revnum
	exit 1 unless last_relevant
	newnum = @@revision_number_mapping[last_relevant.num]
	file.puts "# Node-copyfrom-rev #{revnum} -> #{newnum}<#{last_relevant.num}>" if $debug
	node['Node-copyfrom-rev'] = newnum
      end
    end
    
    # write Revision item
    
    self.copy_to file
    # write nodes
    @nodes.each do |node|
      node.copy_to file
      path = node.path
      while path != "."
	@@last_relevant_for[path] ||= []
	@@last_relevant_for[path] << self
	path = File.dirname(path)
      end
    end
  end


  # add node according to filter
  def process_node node, filter
    
    # collect toplevel creators

    if node.kind == :dir && node.action == :add
      # find toplevel dir creators
      case node.path
      when @@regexp_branches_top, @@regexp_tags_top
      # continue
      when "trunk", @@regexp_trunk_dir, @@regexp_trunk_file, 
	"branches", @@regexp_branches_dir, @@regexp_branches_file,
	"tags", @@regexp_tags_dir
	self.make_relevant!
	# continue
      else
	return
      end

      @@last_relevant_for[node.path] ||= []
      @@last_relevant_for[node.path] << self
      
    else

      case node.path
      when @@regexp_trunk_file, @@regexp_branches_file
	self.make_relevant!
	# continue
      else
	return
      end

    end
    
    STDOUT.puts "# #{@num} is relevant for '#{node.path}'" if $debug
    @nodes << node

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
filter = ARGV.shift
usage "Missing <filter> argument" unless filter

outfile = STDOUT

usage unless dumpfile

STDERR.puts "Debug ON" if $debug

# open .dump file

dump = Dumpfile.new dumpfile

# check dump header and write to outfile

format = Item.new dump

usage "Missing dump-format-version" unless format.type == "SVN-fs-dump-format-version"
usage "Wrong dump format version '#{format.value}'" unless format.value == "2"

format.copy_to outfile

uuid = Item.new dump

unless uuid.type == "UUID"
  usage "Missig UUID"
end

uuid.copy_to outfile

# parse dump file and build in-memory commit structure

rev = lastrev = nil
num = 0
loop do
  item = Item.new dump
  break unless item.pos # EOF
  case item.type
  when "Revision-number"
    # process completed rev according to filter
    rev.process_and_write_to(outfile) if rev

    # start new rev
    rev = Revision.new(dump, item, filter)
    rev.make_relevant! if rev.num == 0
    STDERR.write "#{rev.num}\r" if rev.num % 1000 == 0
    # consistency check - revision numbers must be consecutive
    unless rev.num == num
      STDERR.puts "Have rev #{rev.num}, expecting rev #{num}"
      exit 1
    end
    num += 1
  when "Node-path"
    # add node to current rev
    rev.process_node(Node.new(dump, item), filter)
  when nil
    break # EOF
  else
    STDERR.puts "Unknown type #{item.type} at %08x" % item.pos
  end
end

rev.process_and_write_to(outfile) if rev
