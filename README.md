# Converting a YaST module from SVN to GIT #

## Prerequisites ##

1. git
2. ruby
3. A 'svnadmin dump' of the YaST SVN repo, called *yast-full.dump*
4. The svn2git tool from KDE (http://techbase.kde.org/Projects/MoveToGit/UsingSvn2Git)
5. Some disk space (The YaST svn dump is 4GB already)

## Setup ##

Edit *yast-svn2git.sh* and adapt the path to svn2git (the KDE tool)

Run
>  yast-svn2git.sh *module*
where *module* is a subdirectory below /trunk or
/branches/*branchname* at any time in the SVN history

This will result in a *module* directory with a *svn*
subdir and a yast-*module* **bare** git repo.

## About the conversion ##

The conversion script starts with extracting the relevant SVN
revisions from the full dump into a new dump.
This is done with a Ruby program called dump-splitter.rb

This new dump is then loaded into a new SVN repo. This will only
contain the commits relevant to the choosen module.

The last step is using the KDE svn2git tool to convert from SVN to GIT

## Alternative approach ##

Another approach is to use the new SVN repo and "git svn clone" for
the conversion.

For this use the map2authors.rb Ruby script to convert the yast.map to
an authors.txt file first.

Then start a local svn server
  svnserve --foreground -d -R -r ./*module*/svn
  
and run the conversion
  git svn clone --no-metadata -A authors.txt -Ttrunk -ttags -bbranches svn://localhost:3690 *name-of-git-repo*
