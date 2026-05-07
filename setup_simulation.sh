#!/bin/bash

pushd hardware
rm -rf build
mkdir build
pushd build
/usr/bin/cmake ..
make sim
