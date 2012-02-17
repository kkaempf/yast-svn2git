#
# Revtree.rb
#

$latest_rev_only = false

# Some modules start in a branch and the branch is originating from trunk
# This brings svn2git in trouble since trunk is empty and git has nothing to track
# In this case, we blindly add a file so trunk appears non-empty
# This will get ignored by svn2git if its outside the module
$first_file_in_trunk = "trunk/sound/sound/.cvsignore"
$first_rev_for_file = 2

#
# track if we have any (relevant) nodes adding files to trunk
# sometimes relevant stuff starts in a branch (instead of trunk)
# but the branch is rooted in trunk. Git fails here since it
# tracks files, not directories, and cannot add the branch
# to an empty master (resp. trunk).
#
# So if we ever branch from trunk and trunk is empty, we blindly
# add a file from trunk
#
$have_any_trunk = false

#
# Check if path matches filter
#
def path_matches? path, filter
  path_components = path.split("/").collect! { |p| p.to_sym }
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
  when :"."
    return false
  else
    raise "Unknown path start #{path_components[0].inspect}<#{path}>"
  end
  
  return path_components[filter_pos] == filter
end


class Satsolver::Solvable
  #
  # Intern the pool
  #
  def self.pool= pool
    @@pool = pool
    @@length_id = pool.id("length",1)
    @@pos_id = pool.id("pos",1)
  end

  # string id of 'revision'
  def self.revision_id= id
    @@revision_id = id
  end

  #
  # copy from Dumpfile to outfile
  #
  def copy_to revnum, dump, outfile
    # @pos = input["pos"]
    # cl = @header["Content-length"]
    # @content_size = cl ? cl.to_i : 0
    # @content_pos = @pos + input["cpos"]
    # @size = @content_pos + @content_size - @pos
    content_size = 0
    pos = content_pos = nil
    enhances.each do |rel|
      case rel.name_id
      when @@length_id: content_size = rel.evr.to_i
      when @@pos_id: pos,content_pos = rel.evr.split ","
      else
	STDERR.puts "#{self} enhances #{rel} ?!"
      end
    end
    copyrev = nil
    i = supplements.size
    if i > 0
      copyrev = supplements[i-1].name # last one is highest
    end
    Log.log(1,"copy_to '%s' as %d: pos %s<%08x>, content_pos %s<%08x>, content_size %d; copyrev %s", self, revnum, pos, pos.to_i, content_pos, content_pos.to_i, content_size, copyrev.to_s) if $debug
    pos = pos.to_i
    content_pos = content_pos.to_i
    # a delete node has content_size 0
    size = content_pos + content_size - pos + ((content_size == 0) ? 0 : 1)
    if name_id == @@revision_id
      raise "Revision #{self} has copyrev ?!" if copyrev
      # write revision
      dump.copy_to pos, size, outfile
    else
      if copyrev
	# copy item header line-by-line, replacing Node-copyfrom-rev
	dump.pos = pos
	while (dump.pos < content_pos)
	  line = dump.gets
	  k,v = line.split ":"
	  if k == "Node-copyfrom-rev"
	    outfile.puts "#{k}: #{copyrev}"
	  else
	    outfile.puts line
	  end
	end
	# copy the content
	dump.copy_to content_pos, content_size, outfile
      else
	# write complete node
	dump.copy_to pos, size, outfile
      end
    end
  end

  #
  # Check if item is relevant
  #
  #
  def is_relevant?
    !conflicts.empty?
  end
  
  #
  # Make item relevant
  #
  def make_relevant!
    return if is_relevant?
    rel = @@pool.create_relation( name )
    conflicts << rel
    Log.log(1,"%s made relevant", self) if $debug
  end
  
  #
  # extract copypath, copyrel
  #
  def copypathrev
    return nil if requires.nil? || requires.empty?
    
    # check if this is a copy/move from another module
    copypath = requires[0].name
    copyrev = requires[0].evr.to_i
    Log.log(1,"Node %s was copied from %s:%s", self, copypath, copyrev) if $debug
    [copypath, copyrev]
  end
  
  #
  # replace copyrev with the highest rev
  #
  def replace_copyrev copyrev
    raise "replace_copyrev nil" unless copyrev
    # do we have a new highest ?
    i = supplements.size 
    if i > 0
      highest = supplements[i-1].name.to_i
      return if copyrev.to_i < highest # no new highest
    end
    rel = @@pool.create_relation( copyrev.to_s )
    supplements << rel # tack new highest to end
  end
  
  #
  # Check if node is relevant for filter
  #
  # Check if node modifies (add,change,delete) any of parents path (== dir!)
  #   use to check for deletion of relevant parent dirs
  #       or branches containing relevant files
  #
  # @return path if filter matches
  #
  def is_relevant_for? filter, parents
    pathrel = nil
    # get the one provides representing the Node-path
    self_id = @@pool.id("#{name}_#{version}")
    raise "'#{name}_#{version}' not known for #{self}" if self_id == 0
    provides.each do |rel|
      next if rel.name_id == name_id # skip self-provides
      next if rel.name_id == self_id
      pathrel = rel
      break
    end
    # if no provides match, check if the file matches an obsolete (deletion of path)
    pathrel = obsoletes[0] if pathrel.nil? # delete
    raise "Node #{name} of rev #{rev.name} without path" if pathrel.nil?
    path = pathrel.name
    unless path_matches?(path, filter) || parents[path]
      # this node doesn't touch a relevant path or a parent
      #  still it might be relevant if it copies from a parent
      pathreq = requires[0] # copypath
      return nil unless pathreq # no copypath
      return nil unless parents[pathreq.name]
      Log.log(1, "Node %s with %s copied from %s", self, path, pathreq.name) if $debug
      return path.to_sym
    end
    Log.log(1, "Node %s with %s is relevant", self, path) if $debug

    path
  end

end # Solvable


class Revtree
private

  #
  # Get revision for revnum
  # 
  def get_rev revnum
    @pool.each_provider("revision_#{revnum}") do |r|
      return r
    end
    nil
  end
  
  # Find the node within revnum touching path
  #
  def find_node_for_path_in path, revnum, any_node = false, nodenum = nil
    node_name = "node_#{revnum}"
    highest_node = nil
    node_path = nil
    @pool.each_provider(node_name) do |node|
      node.provides.each do |rel|
	if rel.name.index(path) == 0
	  if any_node
	    v = node.version.to_i
	    next if nodenum && v >= nodenum # too high
	    next if highest_node && v < highest_node.version.to_i # too low
	    highest_node = node
	    node_path = rel.name
	  elsif node.is_relevant?
	    return node, rel.name 
	  end
	end
      end
    end
    return highest_node, node_path
  end

  #
  # Find a revision touching path
  #
  # return the one with the highest revision <= revnum
  #
  # prefer relevant nodes
  #
  # @return revision number
  #
  def find_latest_revnum_before level, path, revnum
    raise "revnum is #{revnum.class}" unless revnum.is_a? Integer
    # now look for revisions providing path
    highest = 0          # highest overall
    highest_relevant = 0 # highest and relevant

    # Look for revisions providing path
    @pool.each_provider(path) do |item|
      next unless item.name_id == @revision_id # skip the nodes
      version = item.version.to_i
      next if version > revnum # this nodes belongs to a future rev
      if version > highest # do we have a new highest ?
	highest = version 
      end
      next unless item.is_relevant?
      if version > highest_relevant # do we have a new highest ?
	highest_relevant = version 
      end
    end
    prefix = " " * level	
    Log.log(1, prefix+"find_latest_revnum_before %s:%d -> highest_relevant %d, highest %d", path, revnum, highest_relevant, highest) if $debug
    return highest_relevant if highest_relevant > 0
    return highest if highest > 0
    return nil
  end

  #
  # Find a node matching path
  #
  # return the one with the highest revision <= revnum
  #
  def find_matching_node_at_or_before path, revnum, nodenum = nil
    raise "revnum is #{revnum.class}" unless revnum.is_a? Integer
    
    # now look for exact node matches
    node = nil
    noderev = 0
    nodevers = 999999
    providers = []
    # Look for nodes providing path
    @pool.each_provider(path) do |item|
      next if item.name_id == @revision_id # thats a revision
      name, version = item.name.split "_" # extract node revision
      version = version.to_i
      next if version > revnum # this nodes belongs to a future rev
      next if version < noderev # we already have a larger rev
      iv = item.version.to_i
      if nodenum && version == revnum # been here before, check lower nodenums
	next if iv >= nodenum # skip if nodenum equal or greater than last
	return node # have matching node in same rev
      end
      next if (noderev == version) && (iv <= nodevers)
      node = item
      noderev = version
      nodevers = iv
    end
    node
  end

  # There's a node with Node-copyfrom-path/Node-copyfrom-rev
  #   pointing to a non-matching path
  #
  # backtrack the revision tree and make revisions for path preceding revnum relevant
  #
  # kind
  #   :file - exact match of path, used to track parent directories or files 
  #   :dir  - copypath from a directory, find the last revisions touching this dir
  #   :tree - copypath from a directory, find all nodes/revisions touching this dir
  #
  # filepath
  #   if given, a file below path (a directory) which originated somewhere else
  #   in this case, find the copypath in the parent chain and track the file there
  #
  # @return: new copyrev
  #
  def backtrack_and_make_relevant level, path, revnum, kind, filepath = nil
    prefix = " " * level
    Log.log(1, prefix+" backtrack %s:'%s', rev <= %d, filepath '%s'", kind, path, revnum, filepath) if $debug

    highest_rev_match = nil
    rev = node = nodenum = nil
    # find / track back path history, making nodes/revs relevant along the way
    loop do
      node_path = nil
      if kind == :file
	# file: find exact match
	node = find_matching_node_at_or_before path, revnum, nodenum
	Log.log(1, prefix+"  find_matching_node_at_or_before file:%s, %s:%s -> '%s'", path, revnum, nodenum, node) if $debug
      else
	# :dir, :tree -> find relevant affecting dir
	if kind == :dir
	  revn = find_latest_revnum_before level+1, path, revnum
	  if revn
	    node, node_path = find_node_for_path_in path, revn
	  else
	    node = nil
	  end
	else
	  node, node_path = find_node_for_path_in path, revnum, true, nodenum
	  if node
	    x, revn = node.name.split "_"
	    revn = revn.to_i
	  else
	    revn = nil
	  end
	end
	if revn
	  Log.log(1, prefix+"  find_node_for_path_in:%s %s:%s provides %s as %s", kind, node, nodenum, path, node_path)
	  if node.nil? && kind != :tree
	    Log.log(1, prefix+"  copied from a non-relevant dir: %s", path)
	    # copied from a non-relevant dir
	    if path == "trunk"
	      # choose the first file in /trunk in order to make it non-empty
	      backtrack_and_make_relevant level+1, $first_file_in_trunk, $first_rev_for_file, :file
	      node = find_matching_node_at_or_before $first_file_in_trunk, $first_rev_for_file
	    else
	      backtrack_and_make_relevant level+1, path, revn, :tree
	      node = find_matching_node_at_or_before path, revn
	    end
	    Log.log(1, prefix+"  find_matching_node_at_or_before %s, %s -> '%s'", path, revn, node) if $debug
	  end
	else # no revn
	  node = find_matching_node_at_or_before path, revnum, nodenum # try exact match if no more touching found
	  node_path = path if node
	  Log.log(1, prefix+"  find_matching_node_at_or_before %s, %s:%s -> '%s'", path, revnum, nodenum, node) if $debug
	end
      end
      if node.nil?
	break if nodenum.nil? # nothing found -> exit
	revnum -= 1 # all nodes checked, continue with previous revision
	nodenum = nil
	next
      end
      if highest_rev_match.nil?
	name, highest_rev_match = node.name.split "_"
	highest_rev_match = highest_rev_match.to_i
      end
      if node.is_relevant? && filepath.nil? && kind != :tree # been there before, and no specific filepath
	Log.log(1, prefix+"  Node is relevant -> return highest_rev_match %s", highest_rev_match);
	return highest_rev_match 
      end
      node.make_relevant!
      name,revnum = node.name.split "_"
      revnum = revnum.to_i
      rev = get_rev revnum
      rev.make_relevant!
      break if kind == :dir
      if node.arch == "add"
	# found the origin
	break if kind != :tree
	break if node_path == path # found origin in :tree mode
      end
      nodenum = node.version.to_i # there might be more in the same revision
      if nodenum.nil? || nodenum == 0
	nodenum = nil 
	revnum -= 1
      end
    end

    if node
      Log.log(1, prefix+"  Have origin for '%s' at %s", path, node) if $debug
      # the node might have been copied
      copypath, copyrev = node.copypathrev
      if copypath
	if filepath
	  # found the origin (copypath) of filepath's parent
	  #   use it to backtrack the filepath's origin
	  newpath = filepath.sub(path,copypath)
	  Log.log(1, prefix+"  Backtrack filepath %s from rev %s", newpath, copyrev) if $debug
	  node.replace_copyrev( backtrack_and_make_relevant(level+1, newpath, copyrev, :file) )
	end
	# backtrack the copypath
	# try history backtrack for relevants first
	k = node.revision.to_sym rescue :file
	new_copyrev = backtrack_and_make_relevant(level+1, copypath, copyrev, k)
	# check exact matches, non-relevants if nothing found
	new_copyrev = backtrack_and_make_relevant(level+1, copypath, copyrev, :file) unless new_copyrev
	node.replace_copyrev( new_copyrev )
	# and fallthrough to backtrack the current path
      else
	# if its not an 'add' we must further backtrack
	unless node.arch == "add"
	  k = node.revision.to_sym rescue :file
	  Log.log(1, prefix+"  Neither copied nor add -> further backtrack");
	  backtrack_and_make_relevant(level+1, path, revnum - 1, k)
	  Log.log(1, prefix+"  Neither copied nor add -> return highest_rev_match %s", highest_rev_match);
	  return highest_rev_match
	end
      end
      # 'add' node found, fallthrough to backtrack parent of path
    else
      # search for 'add' origin didn't succeed
    
      # if kind == :file, this means we backtracked a file path but didn't end up with
      # an 'add' node for that path.
      # this happens if this path belongs to a directory which was copied (copypath) and
      # the file origin (the 'add' node) is in the copypath history.
      # in this case we must backtrack the file's parent dir, find the copypath node, and
      # backtrack the file in the copypath dir tree.

      if filepath.nil? && kind == :file
	filepath = path
      end
    end
    Log.log(1, prefix+"  Parent backtrack for '%s' <= %s", path, revnum) if $debug

    # no match found
    # backtrack directory chain

    # if highest_rev_match hasn't been set yet, use the parent as the highest
    # (this happens if we backtrack a directory which is child of a copied tree)
    
    # start from same revnum since path and parent might've been created simultaneously
    
    parent = File.dirname(path)
    unless parent == "."
      r = backtrack_and_make_relevant( level+1, parent, revnum, :file, filepath )
      highest_rev_match ||= r
    end
    Log.log(1, prefix+"  Backtrack done -> return highest_rev_match %s", highest_rev_match);
    return highest_rev_match
  end


  #
  # check node if its relevant
  #
  #  parents: Hash of path -> revnum of already seen directories
  #    required to catch deletion nodes of parents
  #    and branches containing relevant files
  #
  # return relevant path
  #
  def check_node node, rev, parents
    path = node.is_relevant_for?(@filter, parents)
    return nil unless path
    rev.make_relevant!
    node.make_relevant!

    #
    # Trace back the path in order to get the full history
    #  and the parent directories
    #
    # path being a Symbol means the node copied from a relevant path. Again ensure
    # that the history and parents are complete
    #
    if node.arch != "add" || path.is_a?(Symbol)
      # ensure that we track back to the 'add' node
      kind = node.revision.to_sym rescue :file # node with arch == "delete" has no node.revision (dir/file)
      backtrack_and_make_relevant(0, path.to_s, rev.version.to_i - 1, kind)
    end

    # backtrack Node-copyfrom (if exists)
    copypath, copyrev = node.copypathrev
    if copypath
      new_copyrev = backtrack_and_make_relevant(0, copypath, copyrev, node.revision.to_sym )
      node.replace_copyrev new_copyrev
    end
    path.to_s
  end

  #
  # Check a revision if it is relevant
  #
  # parents: hash of relevant parent dirs, needed to detect relevance of 'delete' nodes
  #
  def check_revision rev, revnum, parents
    new_parents = {}
    return new_parents if rev.is_relevant?
    
    # nodes belonging to a revision all share the revision number as version
    node_name = "node_#{rev.version}"
    relevant_pathes = {} # collect pathes of revision here. 
    # iterate over all nodes of this rev
    nodes = 0
    @pool.each_provider(node_name) do |node|
      nodes += 1
      path = check_node node, rev, parents
      next unless path # node not relevant
      relevant_pathes[path] = true
      copypath, copyrev = node.copypathrev
      new_parents[copypath] = true if copypath
      parent_dir = File.dirname(path)
      next if relevant_pathes[parent_dir] # the parent dir is already in this rev
      new_parents[parent_dir] = true
    end
    
    raise "Expected #{rev.revision} node, got #{nodes} nodes for revision #{rev}" unless rev.revision.to_i == nodes

    return new_parents if new_parents.empty?

    Log.log(1, "Backtrack parents of revision %s : new_parents %s", revnum, new_parents.inspect)
    new_parents.each_key do |dir|
      # backtrack parent dirs (:file == exact match)
      backtrack_and_make_relevant 0, dir, revnum, :file
    end

    new_parents
  end

public
  attr_reader :size

  def initialize solvfile
    @pool = Satsolver::Pool.new
    start = Time.now
    Satsolver::Solvable.pool = @pool
    @repo = @pool.add_solv(solvfile)
    @pool.prepare
    stop = Time.now
    STDERR.puts "Loaded #{solvfile} in #{stop-start} seconds"

    @revision_id = @pool.id("revision",1)
    Satsolver::Solvable.revision_id = @revision_id
    @size = @pool.providers_count @revision_id

    @num = 0
  end


  #
  # Go through all revisions and mark the relevant ones.
  #
  def mark_relevants filter
    Log.log(1, "mark_relevants '#{filter}'") if $debug
    revnum = 0
    @filter = filter.to_sym
    parents = {} # hash of relevant parent dirs, to detect relevance of 'delete' nodes
    while rev = get_rev(revnum)
      if !$quiet && revnum % 1000 == 0
	STDERR.write "#{revnum}\r" 
	STDERR.flush
      end
      new_parents = check_revision rev, revnum, parents
      parents.merge! new_parents
      revnum += 1
    end
  end

  #
  # Go through all revisions and write out the relevant ones.
  # Also assign new numbers to relevant revisions and adapt copyfrom-rev nodes accordingly.
  #
  def write_relevants dump, outfile
    Log.log(1, "write_relevants") if $debug
    
    # write dump header
    @pool.each_provider("SVN-fs-dump-format-version") do |item|
      outfile.puts "#{item.name}: #{item.version}"
      outfile.puts
      outfile.puts "UUID: #{item.arch}"
      outfile.puts
    end
    
    # iterate over revisions (in increasing revision number)
    revnum = 0
    nodes = 0
    i = 0
    while i < @size
      rev = get_rev i.to_s
      if !$quiet && i % 100 == 0
	STDERR.write "#{i}\r" 
	STDERR.flush
      end
      i += 1
      next unless rev.is_relevant?
      Log.log(2, "write rev %d as %d", rev.version, revnum) if $debug
      rev.copy_to revnum, dump, outfile
      j = 0
      node_count = rev.revision.to_i
      # iterate over revision nodes (in increasing node number)
      while j < node_count
	@pool.each_provider("node_#{rev.version}_#{j}") do |node|
	  if node.is_relevant?
	    nodes += 1
	    node.copy_to revnum, dump, outfile
	  end
	  break # expect only one node provider
	end
	j += 1
      end
      revnum += 1
    end
    STDERR.puts "\nwrote #{revnum} revisions and #{nodes} nodes" unless $quiet
  end

  def write_solv name
    STDERR.puts "\nWrite solv to #{name}" unless $quiet
    File.open name, "w+" do |f|
      @repo.write f
    end
  end

end
