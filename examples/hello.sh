#!/bin/sh
# Hello world for the Bash input plugin (example-bash-input).
# fcc parses the supported subset into C and compiles it natively —
# no shell is involved at run time.
#   fcc -c -o hello.o examples/hello.sh
#   gcc -o hello.exe hello.o
name="world"
echo hello "$name"
for i in 1 2 3; do
  echo count "$i"
done
