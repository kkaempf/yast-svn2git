#!/bin/sh
for i in `./svnerrors.sh`; do
  MODULE=$i make
done