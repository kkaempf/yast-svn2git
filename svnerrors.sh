#!/bin/sh
for i in `find . -name stderr.svnadmin -size +0`; do
  j=`dirname $i`
  j=`basename $j .dir`
  echo $j
done