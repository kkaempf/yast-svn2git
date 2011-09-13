# extract-dump-data.rb
#
# Handling a large SVN dump is resource-intensive because the
# dump includes the actual file contents.
#
# Computing the relevant revisions and nodes to extract a sub-directory
# does not need the file contents, just the metadata (esp. node-path and copyfrom-path)
# This, combined with the file positions in the original dump file, can be
# used to make splitting a dump file less resource intensive
#
# Written by Klaus Kämpf <kkaempf@suse.de>
# License: GPL v2 only
#
# = Version history =
#
# Version 1.0
#  Based on https://github.com/kkaempf/yast-svn2git/blob/master/dump-splitter.rb
#
#
# * Syntax of a SVN dump file
# See http://svn.apache.org/repos/asf/subversion/trunk/notes/dump-load-format.txt for details
#

$debug = false

def usage why=nil
  STDERR.puts "***Err: #{why}" if why
  STDERR.puts "Usage: extract-dump-data.rb [--debug] [--quiet] <dumpfile>"
  STDERR.puts "\tExtracts metadata from a svn dump file and writes it to stdout"
  exit 1
end

require 'dumpfile'
require 'item'
require 'node'
require 'revision'

class Item
  def to_yaml outfile, indent = nil
    if indent
      prefix = "  " * (indent-1) + "- "
    else
      prefix = ""
    end
    outfile.puts "#{prefix}pos: #{@pos}"
    prefix = "  " * indent if indent
    outfile.puts "#{prefix}cpos: #{@content_pos - @pos}"
    outfile.puts "#{prefix}order:"
    @order.each do |key|
      outfile.puts "#{prefix}  - [ #{key}, #{@header[key]} ]"
    end
  end
end

class Node
  def to_yaml outfile, indent = nil
    super outfile, indent
  end
end

class Revision
  def to_yaml outfile
    outfile.puts "---"
    super outfile
    unless @nodes.empty?
      puts "nodes:"
      @nodes.each do |node|
	node.to_yaml outfile, 2
      end
    end
  end
end

###################
# Main


# get arguments

dumpfile = nil
loop do
  dumpfile = ARGV.shift
  case dumpfile
  when "--debug"
    $debug = true
  when "--quiet"
    $quiet = true
  else
    break
  end
end

outfile = STDOUT

usage unless dumpfile

STDERR.puts "Debug ON" if $debug

# open .dump file

dump = Dumpfile.new dumpfile

# check dump header and write to outfile

format = Item.new dump

usage "Missing dump-format-version" unless format.type == "SVN-fs-dump-format-version"
usage "Wrong dump format version '#{format.value}'" unless format.value == "2"

outfile.puts "---"
format.to_yaml outfile

uuid = Item.new dump

unless uuid.type == "UUID"
  usage "Missig UUID"
end

outfile.puts "---"
uuid.to_yaml outfile

# parse dump file and write metadata

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
  rev.to_yaml(outfile)
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
