#!/bin/bash

pushd hardware
rm -rf build-sim
mkdir build-sim
pushd build-sim
echo Creating Vivado simulation project in hardware/build-sim...
/usr/bin/cmake -DENABLE_RDMA=OFF -DFDEV_NAME=u55c ..
make sim
