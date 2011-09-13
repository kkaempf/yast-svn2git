# yaml-splitter.rb
# Split SVN dump file according to subdirectory
#
# Written by Klaus Kämpf <kkaempf@suse.de>
# License: GPL v2 only
#
# = Version history =
#
# Version 4.0
# - use YAML based metadata for scanning for relevant revisions
# - improve backtracking of branch/tag/merge points
# - move class definitions to external files
# - switch Relation and Node class from has-an item to is-an item
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
# See http://svn.apache.org/repos/asf/subversion/trunk/notes/dump-load-format.txt for details
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
$quiet = false

# hash of pathname => revision of extra pathes to track
$extra_pathes = {}

# hash of pathes created to bring parents of extra files into existance
# kept here to prevent duplicate creations
$created_extras = {}
def usage why=nil
  STDERR.puts "***Err: #{why}" if why
  STDERR.puts "Usage: [--debug] [--quiet] [--extra <extras>] dump-splitter <dumpfile> <metafile> <filter>"
  STDERR.puts "\tFilters out <filter> from <dumpfile> and <metafile> and writes the result to stdout"
  STDERR.puts "\t--debug adds debug statements as '#' comments to stdout."
  STDERR.puts "\t        This makes the resulting dumpfile unusable with 'svnadmin load'"
  STDERR.puts "\t--quiet supresses displaying the revision count during parsing"
  STDERR.puts "\t--extra add a file containing max-revisions and pathes to consider relevant"
  exit 1
end

require 'dumpfile'
require 'yaml'
require 'item'
require 'node'
require 'revision'
require 'log'

#
# Dirtree represents the complete directory tree from the svn home dir
# @tree is a Hash. For YaST it has :trunk, :branches and :tags as keys.
#  (Symbol instead of String. Will collate identical strings and speed up comparisons)
# Values point to a Hash of one for each sub-dir resp files.
#   Theses Hashes have a special key entry of :"." pointing to the Array of
#   revision numbers affecting this directory/file itself.
#
# Add and Change actions are represented by the positive revision number.
# Delete actions are represented by the negative revision number.
#

class Dirtree
  def initialize
    @tree = {}
  end
  
  #
  # Find the node matching path, kind and action in a revision before revnum
  #
  def find_node revisions, path, kind, action, revnum
    tree = find_rev_match path, kind, action, revnum
    revnum = tree[:"."]
    unless revnum
      raise "No node found for <#{action}>[#{kind}]#{path} @ #{revnum}"
    end
    rev = revisions[revnum]
    rev.nodes.each do |node|
      return node if node.path == path
    end
    raise "Revision #{revnum} has no Node matching <#{action}>[#{kind}]#{path}"
  end

  #
  # Find the revision (<= revnum) matching path, kind, and action
  # return Hash with
  #   :"." -> last rev affecting this path
  #   :"/" -> last rev affecting anything below this path
  #
  def find_rev_match path, kind, action, revnum, flags = {}
    # work on Symbol instead of String. Will collate identical strings and speed up comparisons
    path_components = path.split("/").collect! { |p| p.to_sym }
    #
    # For :delete actions we don't know if the path is a file or directory
    # So we first traverse the Dirtree to find out
    #
    Log.log(2, "find_rev_match <%s>[%s]%s @ %d", action, kind, path, revnum) if $debug
    tree = @tree
    path_components.each do |dir|
      tree[dir] ||= {}
      tree = tree[dir]
      if flags[:affect]
	tree[:"/"] = revnum
      end
      Log.log(2, "tree[%s] -> %s", dir, tree.keys.inspect) if $debug
    end
    if flags[:with_components]
      return tree, path_components
    else
      return tree
    end
  end

  #
  # Add path to Dirtree
  #
  # return Array of path components
  #
  def add path, kind, action, revnum
    tree, components = find_rev_match path, kind, action, revnum, :with_components => true, :affect => true
    tree[:"."] = revnum
    return components
  end

end


class Revtree
private

  #
  # backtrack through revisions making parents of rev (maching path) relevant
  #
  def make_relevant! rev, node, path = "."
    while rev.make_relevant!( (node) ? node : path )
      node = nil
      path = File.dirname(path)
      break if path == "."
    end
  end

  #
  # backtrack the revision tree and make revisions for path preceding revnum relevant
  #
  def backtrack_and_make_relevant path, kind, action, revnum
    Log.log(1, "backtrack '%s'(%s) rev <= %d", path, kind, revnum) if $debug
    tree = @dirtree.find_rev_match path, kind, action, revnum
    lastrev = tree[:"."]
    if lastrev && lastrev > revnum
      Log.log(2, "search rev lower than %d", revnum) if $debug
      lastrev = revnum + 1
      found = nil
      while lastrev > 0
	lastrev -= 1
	rev = @revisions[lastrev]
	rev.nodes.each do |node|
	  next unless node.kind == kind
	  next unless node.action == action
	  next unless node.path == path
	  found = lastrev
	  break
	end
	break if found
      end
      lastrev = found
    end
    unless lastrev
      Log.log(1, "Climb up parent chain for %s", path) if $debug
      # path was not found, so it wasn't explicitly mentioned in any Node
      # This means that one of its parent dirs was copied/moved from somewhere
      # Now climb up the directory chain to find this parent dir
      #   then tack the rest of the path back on and search again
      dir_chain = path.split "/"
      child_chain = []
      node = nil
      while !dir_chain.empty?
	child_chain.unshift dir_chain.pop
	node = @dirtree.find_node @revisions, dir_chain.join("/"), :dir, :add, revnum
	break if node
      end
      unless node
	raise "No backtrack #{path} for rev #{revnum} possible"
      else
	Log.log(1,"Node %s found", node.to_s) if $debug
	copypath = node['Node-copyfrom-path']
	raise "Node #{node} matches a parent of #{path} but has no Node-copyfrom-path" unless copypath
	copyrev = node['Node-copyfrom-rev']
	Log.log(1, "Parent originated from %s at %d", copypath, copyrev) if $debug
	#   then tack the rest of the path back on and search again
	child_chain.unshift copypath
	return backtrack_and_make_relevant child_chain.join("/"), kind, action, copyrev
      end
    end
    rev = @revisions[lastrev]
    node = rev.make_relevant! path
    return unless node # just a rev

    #
    # We have a Node
    #
    # now backtrack two pathes
    # 1. the parent chain leading to the node.path
    # 2. the copyfrom-path of the node (if existing)
    parent = File.dirname(node.path)
    unless parent == "."
      Log.log(1, "Backtrack parent") if $debug
      backtrack_and_make_relevant parent, :dir, node.action, rev.num
    end
    copypath = node['Node-copyfrom-path']
    if copypath
      revnum = node['Node-copyfrom-rev']
      Log.log(1, "Backtrack copypath") if $debug
      backtrack_and_make_relevant copypath, node.kind, node.action, revnum
    end
  end

  def check_node node, rev
    # collect pathnames
    # collect all of them since they might be referenced via copyfrom-path in later revisions
    #
    path_components = @dirtree.add node.path, node.kind, node.action, rev.num

    # check if we can apply the filter

    filter_pos = nil
    case path_components[0]
    when :trunk
      filter_pos = 1 # assume "trunk/<filter>"
    when :branches
      filter_pos = 2 # assume "branches/<branch>/<filter>"
    when :tags
      filter_pos = 2 # assume "tags/<tag>/<filter>"
    when :users, :reipl # private branches
      return false
    else
      STDERR.puts "Unknown path start #{path_components[0].inspect}<#{node.path}> at rev #{rev.num}"
      return false
    end

    return false unless path_components[filter_pos] == @filter

    rev.make_relevant! node
    Log.log(2, "Node %s is relevant for rev %d", node.path, rev.num) if $debug

    # check if this is a copy/move from another module
    copypath = node['Node-copyfrom-path']

    return true unless copypath
    
    copyrev = node['Node-copyfrom-rev']
    Log.log(1, "Node-copyfrom '%s'@%d for '%s'@%d", copypath, copyrev, node.path, rev.num) if $debug

    backtrack_and_make_relevant copypath, node.kind, node.action, copyrev
    true
  end

  #
  # Check a revision if it is relevant
  #
  def check_revision rev
    unless rev.is_relevant # already checked
      rev.nodes.each do |node|
	if check_node node, rev
	  rev.make_relevant!
	end
      end
    end
    rev.is_relevant
  end

public
  
  def initialize size = 1
    @size = size

    @revisions = Array.new(@size)

    @dirtree = Dirtree.new

    @num = 0

  end
  
  def << rev
    if !$quiet && rev.num % 1000 == 0
      STDERR.write "#{rev.num}\r" 
      STDERR.flush
    end
    unless rev.num == @num
      raise "Have rev #{rev.num}, expecting rev #{@num}"
    end
    @revisions[@num] = rev
    @num += 1
  end

  def resize
    Log.log(1,"Resizing to %d elements", @num) if $debug
    @revisions[@num..-1] = nil
  end

  #
  # Go through all revisions and mark the relevant ones.
  #
  def mark_relevants filter
    @filter = filter.to_sym
    total = 0
    @revisions.each do |rev|
      break if rev.nil?
      if !$quiet && rev.num % 10 == 0
	STDERR.write "#{rev.num}\r" 
	STDERR.flush
      end
      Log.log(1, "check rev %d", rev.num) if $debug
      if check_revision rev
	total += 1
      end
    end
    STDERR.write "\n#{total} revisions are relevant" unless $quiet
  end

  #
  # Go through all revisions and write out the relevant ones.
  # Also assign new numbers to relevant revisions and adapt copyfrom-rev nodes accordingly.
  #
  def write_relevants dump, outfile
    revnum = 0
    @revisions.each do |rev|
      break if rev.nil?
      next unless rev.is_relevant
      rev.newnum = revnum
      if !$quiet && rev.newnum % 100 == 0
	STDERR.write "#{rev.newnum}\r" 
	STDERR.flush
      end
      Log.log(1, "write rev %d as %d", rev.num, rev.newnum) if $debug
      revnum += 1
      if rev.has_copyfrom_nodes?
	# there are nodes with 'copyfrom-rev' entries pointing to past (already
        # written) revisions. Adapt those to the new numbers.
	rev.nodes.each do |node|
	  copyfrom = node['Node-copyfrom-rev']
	  next unless copyfrom # nothing to rewrite
	  # get the old revision and do some consistency checks.
	  fromrev = @revisions[copyfrom]
	  raise "Node of revision #{rev} points to non-existing rev #{fromrev}" unless fromrev
	  raise "Node of revision #{rev} points to non-relevant rev #{fromrev}" unless fromrev.is_relevant
	  # the old revision must be already written
	  fromrevnum = fromrev.newnum
	  raise "Node of revision #{rev} points to non-written rev #{fromrev}" unless fromrevnum
	  node['Node-copyfrom-rev'] = fromrevnum
	end
      end
      rev.copy_to dump, outfile
    end
  end

end

###################
# Main


# get arguments

dumpfile = nil
yaml = nil
extras = nil
loop do
  dumpfile = ARGV.shift
  case dumpfile
  when "--debug"
    $debug = true
  when "--yaml"
    yaml = true
  when "--quiet"
    $quiet = true
  when "--extra"
    extras = ARGV.shift
  else
    break
  end
end

usage "Missing <dumpfile> argument" unless dumpfile

metafile = ARGV.shift
usage "Missing <metafile> argument" unless metafile

filter = ARGV.shift
usage "Missing <filter> argument" unless filter

outfile = STDOUT

usage unless metafile

if $debug
  STDERR.puts "Debug ON" 
  Log.level = 1
end

if extras
  # Extras is
  # [+|-] [F|D] <rev> <path>
  #  0     1     2     3
  File.open(extras, "r") do |f|
    while (l = f.gets)
      lx = l.split(" ")
      usage "Bad line format in #{extras}: #{l}" unless lx.size == 4
      path = lx[3].chomp
      $extra_pathes[path] = {
	:action => (lx[0] == '+')? :add : :delete,
	:kind => (lx[1].upcase == 'D') ? :dir : :file,
        :revnum => lx[2].to_i }
#      STDERR.puts "#{$extra_pathes[path].inspect} #{path}" unless $quiet
    end
  end
end

# open input files

meta = File.open(metafile,"r")
dump = Dumpfile.new(dumpfile)

############################################
#
# parse metafile as YAML documents
#

# state machine: :format -> :uuid -> :revzero -> :revisions
# check dump header and write to outfile

state = :format

revtree = Revtree.new(70000)

Log.name = "#{filter}.debug-parse"

STDERR.puts "Reading meta file #{metafile}" unless $quiet
start_time = Time.now
YAML.each_document(meta) do |doc|
  case state
  when :format
    format = Item.new doc
    usage "Missing dump-format-version, have '#{format.type}'" unless format.type == "SVN-fs-dump-format-version"
    usage "Wrong dump format version '#{format.value}'" unless format.value == 2
    format.copy_to dump, outfile
    state = :uuid
  when :uuid
    uuid = Item.new doc
    unless uuid.type == "UUID"
      usage "Missig UUID"
    end
    uuid.copy_to dump, outfile
    state = :revzero
  when :revzero
    rev = Revision.new doc
    revtree << rev
    rev.make_relevant!
    state = :revisions
  when :revisions
    rev = nil
    begin
      rev = Revision.new doc
    rescue EOFError
      break
    rescue ItemIsNotARevision => e
      STDERR.puts "Not a Revision '#{e.message}'"
      break
    rescue ItemIsNotANode => e
      STDERR.puts "Not a Node '#{e.message}'"
      break
    end
    revtree << rev
  end
end
revtree.resize
end_time = Time.now
STDERR.puts unless $quiet
STDERR.puts "Metadata read in #{end_time - start_time} seconds" unless $quiet

Log.name = "#{filter}.debug-mark"

STDERR.puts "Marking relevant revisions" unless $quiet
start_time = Time.now
revtree.mark_relevants filter
end_time = Time.now
STDERR.puts "Marked in #{end_time - start_time} seconds" unless $quiet

Log.name = "#{filter}.debug-write"

start_time = Time.now
STDERR.puts "Writing relevant revisions" unless $quiet
revtree.write_relevants dump, outfile
end_time = Time.now
STDERR.puts "Write done in #{end_time - start_time} seconds" unless $quiet

Log.close

