#!/bin/sh

#
# Script designed to be run for development purposes only.
#

"${SUEXEC:-doas}" make APPSCRIPT_VERSION=`make -V APPSCRIPT_VERSION`+`git rev-parse HEAD`
