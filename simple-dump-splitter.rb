# dump-splitter
# Split SVN dump file according to sub-directories
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
  attr_reader :num, :newnum, :nodes
  @@outnum = 0
  
  def initialize dump, item
    @item = item
    @num = item.value.to_i
    @nodes = []
    @newnum = -1
    @pos = dump.current
    dump.skip item.content_size
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
    @item[@item.type] = @newnum
    @@outnum += 1
    @item.copy_to file
    file.puts
  end

  def to_s
#    s = @nodes.map{ |x| x.to_s }.join("\n\t")
    "Rev #{@newnum}<#{@num}> - #{@nodes.size} nodes, @ %08x" % @item.pos
  end
  
end

#
# revision tree
#
# A <toplevel_dir> is one matching trunk/<dir>, branches/<branch>/dir
#
#
class Revtree

  attr_reader :last_relevant_for
  def initialize
    # Hash of <toplevel_dir> => <revision creating it>
    # e.g. "trunk", "branches", "tags", "trunk/<dir>", "branches/<branch>", "branches/<branch>/<dir>"
    @toplevel_creators = {}
    
    # Hash of <subdir> => <toplevel_dir> => <last relevant revision for subdir>
    @last_relevant_for = {}
    
    # All revisions
    #  fixed size for performance reasons
    #  64775 == number of revisions in yast2 dump
    @revisions = Array.new(64775)
    
    # remember already created pathes as we process the revtree
    @created_pathes = {}

  end

  # add revision to revtree
  def add rev, filter = nil
    # consistency check
    if @revisions[rev.num]
      raise "Expected rev #{rev}, got #{@revisions[rev.num]}"
    end
    @revisions[rev.num] = rev

    if rev.num % 100 == 0
      STDERR.write "#{rev.num}\r"
      STDERR.flush
    end

    rev.nodes.each do |node|
      # find toplevel dir creators
      case node.path
      when "trunk", "branches", "tags", %r{branches/([^/]+)$}, %r{tags/([^/]+)$}
	if node.kind == :dir && node.action == :add
	  @toplevel_creators[node.path] = rev
	end
      when %r{trunk/([^/]+)$}, %r{branches/([^/]+)/([^/]+)$}, %r{tags/([^/]+)/([^/]+)$}
	if node.kind == :dir && node.action == :add
	  @toplevel_creators[node.path] = rev
	end
      
      # no need to match tags here (, %r{(tags/([^/]+)/([^/]+))/.*$})
      when %r{(trunk)/([^/]+)/.*$}, %r{(branches/([^/]+))/([^/]+)/.*$}
#        STDERR.puts "#{node.path} -> <#{$1}> <#{$2}> <#{$3}>"
	subdir = $3 ? $3 : $2
	path = $1 # outer match
	subdir_relevant = @last_relevant_for[subdir] || {}
	subdir_relevant[path] = rev
	@last_relevant_for[subdir] ||= subdir_relevant
      end
      
      # if applicable, rewrite Node-copyfrom-path/Node-copyfrom-rev to the last relevant revision for this subdir
      copyfrom_path = node['Node-copyfrom-path']
      if copyfrom_path
	path = subdir = nil
	case copyfrom_path
	when "trunk", %r{branches/([^/]+)$}
	  path = copyfrom_path
	when %r{(trunk)/([^/]+)(/.*)?$}
	  path = $1
	  subdir = $2
	  if filter && subdir != filter # the check here costs performance, to be optimized
	    next
	  end
	when %r{(branches/([^/]+))/([^/]+)(/.*)?$}
	  path = $1
	  subdir = $3
	  if filter && subdir != filter # the check here costs performance, to be optimized
	    next
	  end
	else
	  next
	end
	relevants = @last_relevant_for[filter]
	unless relevants
	  STDERR.puts "Nothing relevant found for #{filter} at #{copyfrom_path}"
	  next
	end
	last_relevant = relevants[copyfrom_path]
	if last_relevant
#	  file.puts "# rev #{last_relevant} was last in #{copyfrom_path}" if $debug
#	  file.puts "# rewrite from #{node['Node-copyfrom-rev']} to #{last_relevant.num}" if $debug
	  node['Node-copyfrom-rev'] = last_relevant.num 
	end
      end # if copyfrom_path
    end # each node
  end

  def rewrite_copyfrom_rev node, relevants, file
    copyfrom = node['Node-copyfrom-rev']
    if copyfrom
      newnum = @revisions[copyfrom.to_i].newnum
      if newnum < 0
	path = node['Node-copyfrom-path']
	file.puts "# rev #{copyfrom} not relevant, look for #{path}" if $debug
	rev = nil
	loop do
	  rev = relevants[path]
	  break if rev && @revisions[rev.num].newnum > 0
	  rev = @toplevel_creators[path]
	  break if rev && @revisions[rev.num].newnum > 0
	  path = File.dirname(path)
	  break if path == "."
	end
	if rev
	  newnum = @revisions[rev.num].newnum
	  file.puts "# rev #{newnum}<#{rev.num}> is relevant for #{path}" if $debug
	else
	  file.puts "# *** No revision found !" if $debug
	  return
	end
      end
      file.puts "# rewrite #{copyfrom} to #{newnum}" if $debug
      node['Node-copyfrom-rev'] = newnum
    end
  end

  # backtrack to find (unwritten) toplevel path creator revisions
  #   relevants: Hash of <toplevel> => <revision> for last relevant revision in toplevel dir
  #
  def backtrack path, relevants, outfile
    return nil if @created_pathes[path]
    dirname = File.dirname(path)
    outfile.puts "# backtrack #{path} -> #{dirname}" if $debug
    # recursive call if path has a subdir
    backtrack(dirname, relevants, outfile) unless dirname == "."

    @created_pathes[path] = true

    r = @toplevel_creators[path]
    unless r
      outfile.puts "# no creator found for #{path}" if $debug
      # no creator
      return
    end
    
    # find "Node-copyfrom-path" nodes and backtrack those pathes
    r.nodes.each do |node|
      copyfrom = node["Node-copyfrom-path"]
      next unless copyfrom
      outfile.puts "# backtrack Node-copyfrom-path: #{copyfrom}" if $debug
      backtrack copyfrom, relevants, outfile
    end

    outfile.puts "# create #{path}, #{r}" if $debug
    r.copy_to outfile
    r.nodes.each do |node|
      if node.kind == :dir && node.action == :add
	@created_pathes[node.path] = true
      end
      rewrite_copyfrom_rev node, relevants, outfile
      node.copy_to outfile
    end
    return
  end

  # process revision tree according to filter
  #  and write to outfile
  #
  def process filter, outfile

    # start new process of complete Revtree
    @created_pathes = {}

    # pre-build relevant matches
    regexp_trunk_dir = Regexp.new("trunk/#{filter}$")
    regexp_trunk_file = Regexp.new("trunk/#{filter}/.*$")
    regexp_branches_dir = Regexp.new("branches/([^/]+)/#{filter}$")
    regexp_branches_file = Regexp.new("branches/([^/]+)/#{filter}/.*$")
    regexp_tags_dir = Regexp.new("tags/([^/]+)/#{filter}$")
    regexp_tags_file = Regexp.new("tags/([^/]+)/#{filter}/.*$")

    # just look at relevant revisions for our filter
    relevants = @last_relevant_for[filter] || {}

    STDERR.puts "No relevant rev for #{filter}" if relevants.empty?

    if $debug
      outfile.puts "# Relevants for #{filter}"
      relevants.each do |p,r|
	outfile.puts "# rev #{r.num} -> path #{p}"
      end
    end
    # consistency check for revision numbers
    num = -1
    
    # iterate over all revisions, checking for relevant ones
    @revisions.each do |rev|
      
      # consistency check
      num += 1
      unless rev
	STDERR.puts "No rev #{num}"
	next
      end
      
      # there are revisions without nodes.
      # dont know exactly what to do with them, so consider them relevant
      #
      if rev.nodes.empty?
	rev.copy_to outfile
	next
      end

      #
      # now check the nodes attached to the revision for relevant ones
      #
      
      # remember if the revision item was already written
      rev_written = false
      lastrev = nil

      # iterate over revision nodes
      rev.nodes.each do |node|
    
        # check for relvant nodes

        path = node.path
	case path
	when regexp_trunk_dir, regexp_branches_dir, regexp_tags_dir
	  # relevant dir
	  #  if its a add, backtrack to write revisions creating the directory path
	  if node.action == :add
	    copyfrom = node["Node-copyfrom-path"]
	    if copyfrom
	      # if node has a "Node-copyfrom-path:" key, backtrack this dir also
	      outfile.puts "# backtrack Node-copyfrom-path: #{copyfrom}, from #{rev.num}" if $debug
	      backtrack copyfrom, relevants, outfile
	    end
	  end
	  outfile.puts "# #{path} is a relevant dir of #{rev.num}" if $debug
	  # backtrack at parent dir since we write this node below
	  backtrack File.dirname(path), relevants, outfile
	  @created_pathes[path] = true
	when regexp_trunk_file, regexp_branches_file, regexp_tags_file
	  # relevant file
	  backtrack File.dirname(path), relevants, outfile
	else
	  # not relevant
	  next # skip this node
	end

	# this node is relevant
	
	# write revision item (if not done before)
	unless rev_written
	  rev.copy_to outfile
	  rev_written = true
	end
	
	# write the node

	rewrite_copyfrom_rev node, relevants, outfile
	node.copy_to outfile

      end # each node

    end # each revision

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

revtree = Revtree.new

# parse dump file and build in-memory commit structure

rev = lastrev = nil
num = 0
loop do
  item = Item.new dump
  break unless item.pos # EOF
  case item.type
  when "Revision-number"
    # add completed rev to internal structure
    revtree.add(rev, filter) if rev

    # start new rev
    rev = Revision.new(dump, item)
    # consistency check - revision numbers must be consecutive
    unless rev.num == num
      STDERR.puts "Have rev #{rev.num}, expecting rev #{num}"
      exit 1
    end
    num += 1
  when "Node-path"
    # add node to current rev
    rev << Node.new(dump, item)
  when nil
    break # EOF
  else
    STDERR.puts "Unknown type #{item.type} at %08x" % item.pos
  end
end

revtree.add(rev, filter) if rev

if filter
  revtree.process(filter, outfile)
else
  revtree.last_relevant_for.each_key do |filter|
    puts filter
    File.open("#{subdir}.dump", "w") do |outfile|
      revtree.process(filter, outfile)
    end
  end
end
