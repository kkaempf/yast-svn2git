# dump-splitter.rb
# Split SVN dump file according to subdirectory
#
# Written by Klaus Kämpf <kkaempf@suse.de>
# License: GPL v2 only
#
# = Version history =
#
# Version 5.0
# - use .solv (satsolver) based metadata for scanning of relevant revisions and nodes
#   (decreases loading time from ~55 secs to ~0.3 sec)
#
# Version 4.0 (unpublished)
# - use YAML based metadata for scanning of relevant revisions
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
  STDERR.puts "Usage: [--debug] [--quiet] [--extra <extras>] dump-splitter <dumpfile> <solvfile> <filter>"
  STDERR.puts "\tFilters out <filter> from <dumpfile> and <metafile> and writes the result to stdout"
  STDERR.puts "\t--debug adds debug statements as '#' comments to stdout."
  STDERR.puts "\t        This makes the resulting dumpfile unusable with 'svnadmin load'"
  STDERR.puts "\t--quiet supresses displaying the revision count during parsing"
  STDERR.puts "\t--extra add a file containing max-revisions and pathes to consider relevant"
  exit 1
end

$:.unshift File.dirname(__FILE__)
require 'dumpfile'
require 'log'
require 'satsolver'
require 'revtree'

###################
# Main


# get arguments

dumpfile = nil
solvfile = nil
filter = nil
extras = nil
loop do
  arg = ARGV.shift
  case arg
  when nil
    break
  when "--debug"
    if $debug
      Log.level = 2
    else
      $debug = true
      STDERR.puts "Debug ON" 
      Log.level = 1
    end
  when "--yaml"
    yaml = true
  when "--quiet"
    $quiet = true
  when "--extra"
    extras = ARGV.shift
  else
    if dumpfile
      if solvfile
	if filter
	  usage "Excessive arguments"
	else
	  filter = arg
	end
      else
	solvfile = arg
      end
    else
      dumpfile = arg
    end
  end
end

usage "Missing <dumpfile> argument" unless dumpfile
usage "Missing <solvfile> argument" unless solvfile
usage "Missing <filter> argument" unless filter

outfile = STDOUT

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

revtree = Revtree.new(solvfile)

STDERR.puts "Scanning #{revtree.size} revisions for '#{filter}'" unless $quiet


Log.name = "#{filter}.debug-mark"

STDERR.puts "Marking relevant revisions" unless $quiet
start_time = Time.now
revtree.mark_relevants filter
end_time = Time.now
STDERR.puts "Marked in #{end_time - start_time} seconds" unless $quiet

revtree.write_solv "#{solvfile}-marked-#{filter}"

dump = Dumpfile.new(dumpfile)

Log.name = "#{filter}.debug-write"

start_time = Time.now
STDERR.puts "Writing relevant revisions" unless $quiet
revtree.write_relevants dump, outfile
end_time = Time.now
STDERR.puts "Write done in #{end_time - start_time} seconds" unless $quiet

Log.close

