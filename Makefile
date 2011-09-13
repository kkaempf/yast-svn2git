# default rule

all: git

git: svn
	-echo "Convert SVN to GIT"
	# convert svn to bare git repo
	(cd $(MODULE).dir; rm -rf yast-$(MODULE); /abuild/projects/svn2git/svn-all-fast-export --debug-rules --add-metadata --identity-map ../yast.map --rules ../yast.rules svn > stdout.svn2git 2> stderr.svn2git)

svn: extract
	-echo "Create new SVN repo"
	# load the splitted dump into a new svn repo
	(cd $(MODULE).dir; rm -rf svn; mkdir svn; cd svn; svnadmin create .; svnadmin load . < ../dump > ../stdout.svnadmin 2> ../stderr.svnadmin)

extract: moduledir
	-echo "Extracting relevant revisions for $(MODULE)"
# split the full dump
	(cd $(MODULE).dir; ruby ../dump-splitter.rb --debug ../../yast-full.dump ../yast-full.solv $(MODULE) > dump)

moduledir: module.rule
	rm -rf $(MODULE).dir
	mkdir $(MODULE).dir

module.rule: modulename
	-echo "declare MODULE=$(MODULE)" > module.rule

modulename:
	-if test -z "$(MODULE)"; then echo "Module name missing, set MODULE="; exit 1; fi

clean:
	rm -rf svn
	rm -f stderr stdout
	rm -f *.log
