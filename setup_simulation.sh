#!/bin/bash

pushd hardware
rm -rf build-sim
mkdir build-sim
pushd build-sim
/usr/bin/cmake ..
make sim
