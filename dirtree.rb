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
