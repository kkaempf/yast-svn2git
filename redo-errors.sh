#!/bin/sh
#
# redo-errors.sh
#
# Run 'svnerrors.sh' to detect svn import errors and
# re-run the conversion/filter process for these modules.
#
#
for i in `./svnerrors.sh`; do
  MODULE=$i make
done