# dump2solv.rb
#
# Handling a large SVN dump is resource-intensive because the
# dump includes the actual file contents.
#
# Computing the relevant revisions and nodes to extract a sub-directory
# does not need the file contents, just the metadata (esp. node-path and copyfrom-path)
# This, combined with the file positions in the original dump file, can be
# used to make splitting a dump file less resource intensive.
#
# Additionally, this uses the satsolver library for storing the metadata.
#
# Written by Klaus Kämpf <kkaempf@suse.de>
# License: GPL v2 only
#
# = Version history =
#
# Version 1.0
#  Based on https://github.com/kkaempf/yast-svn2git/blob/master/extract-dump-data.rb
#
#
# * Syntax of a SVN dump file
# See http://svn.apache.org/repos/asf/subversion/trunk/notes/dump-load-format.txt for details
#
# Use of Solvables
#
# Revision
# --------
# name = 'revision'
# version = revision number
# release = number of nodes
# Enhances: pos = <pos>,<content_pos>
#           lenght = <content-length>
# Provides: $self
#           <all parent pathes of nodes>
# Conflicts: <name> if relevant
#
# Node
# ----
# name = 'node_<revision-number>'
# version = relative node number (counting from 0)
# arch = <action> : { add, change, delete, replace }
# Enhances: pos = <pos>,<content_pos>
#           lenght = <content-length>
# Provides: $self
#           <Node-path>
# Requires:  <Node-copyfrom-path> = <Node-copyfrom-rev>
# Conflicts: <name> if relevant
#

$debug = false

def usage why=nil
  STDERR.puts "***Err: #{why}" if why
  STDERR.puts "Usage: dump2solv.rb [--debug] [--quiet] <dumpfile> [<solvfile>]"
  STDERR.puts "\tExtracts metadata from a svn dump file and writes it to solvfile"
  exit 1
end

require 'dumpfile'
require 'item'
require 'node'
require 'revision'
require 'log'

require 'satsolver'

#
# Convert Item data (pos, cpos, Prop-content-length, Content-length) to relations
#
# returns list of Relations
def item_to_relation(pool, item)
  # Enhances: pos = <pos>,<cpos>
  posrel = pool.create_relation( "pos", Satsolver::REL_EQ, "#{item.pos},#{item.content_pos}" )
  
  clen = item['Content-length']
  # Enhances: length = content-length
  lenrel = clen ? pool.create_relation("length", Satsolver::REL_EQ, "#{clen}") : nil
  [posrel, lenrel]
end

#
# Convert Revision rev to a Solvable and add it to Repo repo
#
def add_rev_as_solvable(repo, rev)
  # Revision-<revnum>-<number-of-nodes>
  rsolv = repo.create_solvable("revision", "#{rev.num}-#{rev.nodes.size}", "")
  posrel, lenrel = item_to_relation(repo.pool, rev)
  rsolv.enhances << posrel
  rsolv.enhances << lenrel if lenrel
  rsolv.provides << repo.pool.create_relation( "revision_#{rev.num}" )

  dirs = {}
  i = 0
  rev.nodes.each do |node|
    # node-<revnum>-<nodenum>
    nsolv = repo.create_solvable("node_#{rev.value}", "#{i}-#{node.kind}", node.action.to_s)
    nsolv.provides << repo.pool.create_relation("node_#{rev.value}_#{i}")
    i += 1
    posrel, lenrel = item_to_relation(repo.pool, node)
    nsolv.enhances << posrel
    nsolv.enhances << lenrel if lenrel

    pathrel = repo.pool.create_relation( node.path )
    nsolv.provides << pathrel
    nsolv.obsoletes << pathrel if node.action == :delete

    copyfrom = node['Node-copyfrom-path']
    if copyfrom
      copyrev = node['Node-copyfrom-rev']
      rel = repo.pool.create_relation( copyfrom, Satsolver::REL_EQ, copyrev )
      nsolv.requires << rel
    end
    path = node.path
    dirs[path] = 1 # this path is explicit in the node
    loop do
      path = File.dirname(path)
      break if path == "."
      dirs[path] ||= true
    end
  end
  # now add all parent dirs as 'provides' of the revision
  #
  # There are two kinds of 'provides'
  # 1. dirnames of files/dirs touched by the nodes
  #    these are flagged with a revision since we need to backtrack them
  # 2. parents of 1. (all directory prefixes)
  #    these are added without revision
  #    and used to find the latest rev touching a specific path during backtrack
  #
  # extract real parent dirs
  parents = []
  dirs.each do |dir,flag|
    next if flag == 1 # explicit path in node - skip it, provide real parents only
    parents << dir
  end
  # sort them in reverse order, so we start with longest path
  dirs = {} # <path> -> <boolean>, true for case 1, false for case 2
#  STDERR.puts rsolv
  # 
  parents.sort.reverse.each do |dir|
#    STDERR.puts "dir #{dir}"
    if dirs[dir] == false # parent of dirs we already added
      rel = repo.pool.create_relation( dir, Satsolver::REL_EQ, rsolv.name )
    else
#    STDERR.puts "dir! #{dir}"
      rel = repo.pool.create_relation( dir )
      dirs[dir] == true
      loop do
	dir = File.dirname(dir)
	break if dir == "."
	dirs[dir] = false
      end
    end
    rsolv.provides << rel
  end
end

###################
# Main


# get arguments

dumpfile = nil
solvfile = nil

loop do
  arg = ARGV.shift
  case arg
  when "--debug"
    $debug = true
  when "--quiet"
    $quiet = true
  when nil
    break
  else
    if dumpfile
      if solvfile
	usage "Excessive args"
      else
	solvfile = arg
      end
    else
      dumpfile = arg
    end
  end
end

usage unless dumpfile

STDERR.puts "Debug ON" if $debug

# open .dump file

dump = Dumpfile.new dumpfile

unless solvfile
  solvfile = "#{File.basename(dumpfile,".*")}.solv"
end

pool = Satsolver::Pool.new
repo = pool.create_repo(File.basename(solvfile,".*"))

# check dump header and write to outfile

format = Item.new dump

usage "Missing dump-format-version" unless format.type == "SVN-fs-dump-format-version"
usage "Wrong dump format version '#{format.value}'" unless format.value == "2"

uuid = Item.new dump

unless uuid.type == "UUID"
  usage "Missig UUID"
end

# Solvable 1 -> Header
solv = repo.create_solvable(format.type, format.value, uuid.value)

# parse dump file and create Solvables

rev = lastrev = nil
num = 0
loop do
  begin
    rev = Revision.new(dump)
  rescue EOFError
    break
  rescue ItemIsNotANode => e
    STDERR.puts "Not a Node '#{e.message}'"
    break
  rescue ItemIsNotARevision => e
    STDERR.puts "Not a Revision '#{e.message}'"
    break
  end
  add_rev_as_solvable(repo, rev)
  if !$quiet && rev.num % 1000 == 0
    STDERR.write "#{rev.num}\r" 
    STDERR.flush
  end
  # consistency check - revision numbers must be consecutive
  unless rev.num == num
    STDERR.puts "Have rev #{rev.num}, expecting rev #{num}"
    exit 1
  end
  num += 1
end

File.open(solvfile, "w+") do |f|
  repo.write(f)
end