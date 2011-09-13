#!/bin/sh
#
# yast-svn2git.sh
# Script to extract a YaST module from SVN to GIT
#
# Usage:
#  yast-svn2git.sh <module>
#
#  <module> must match a subdir at /trunk/<subdir> or /branches/<branch>/<subdir>
#  anywhere in the SVN history
#
#
module=${1}
if test -z ${module}; then
  echo "Module name missing"
  exit 1
fi

echo "declare MODULE=${module}" > module.rule

rm -rf ${module}.dir
mkdir ${module}.dir

echo "Extracting relevant revisions"
# split the full dump
ruby dump-splitter.rb --debug ../yast-full.dump yast-full.solv ${module} > ${module}.dir/dump

echo "Create new SVN repo"
# load the splitted dump into a new svn repo
(cd ${module}.dir;
rm -rf svn;
mkdir svn;
cd svn;
svnadmin create .; svnadmin load . < ../dump > ../stdout.svnadmin 2> ../stderr.svnadmin;
cd ../..)

echo "Convert SVN to GIT"
# convert svn to bare git repo
(cd ${module}.dir;
rm -rf yast-${module};
/abuild/projects/svn2git/svn-all-fast-export --debug-rules --add-metadata --identity-map ../yast.map --rules ../yast.rules svn > stdout.svn2git 2> stderr.svn2git;
cd ..)
