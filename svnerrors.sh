#!/bin/sh
#
# Find failed svn imports by looking for non-empty stderr.svnadmin files
#
for i in `find . -name stderr.svnadmin -size +0`; do
  j=`dirname $i`
  j=`basename $j .dir`
  echo $j
done