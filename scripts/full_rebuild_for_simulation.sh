# 1. Purge any previously installed Coyote/libstf/parcore/oasis artifacts. These sit on
#    $HOME/opt/include, which is a PUBLIC include dir of the `libstf` CMake target (via
#    JEMALLOC_INCLUDE_DIRS) and therefore leaks into every downstream target's include path.
#    If left behind, stale headers here can silently shadow the fresh ones checked out below,
#    even though the library itself gets rebuilt and reinstalled correctly.
rm -rf $HOME/opt/include/coyote $HOME/opt/include/libstf $HOME/opt/include/parcore $HOME/opt/include/oasis \
       $HOME/opt/lib/libcoyote.so $HOME/opt/lib/liblibstf.so $HOME/opt/lib/libparcore.so $HOME/opt/lib/liboasis.so \
       $HOME/opt/lib/cmake/Coyote $HOME/opt/lib/cmake/libstf $HOME/opt/lib/cmake/parcore $HOME/opt/lib/cmake/oasis

# 2. Rebuild and reinstall the simulation-configured software stack
cd /local/home/smalinin/oasis && \
rm -rf software/build && \
cmake -S software -B software/build \
  -DCMAKE_INSTALL_PREFIX=$HOME/opt -DCMAKE_PREFIX_PATH=$HOME/opt \
  -DCMAKE_DISABLE_FIND_PACKAGE_Coyote=ON \
  -DCMAKE_DISABLE_FIND_PACKAGE_libstf=ON \
  -DCMAKE_DISABLE_FIND_PACKAGE_parcore=ON \
  -DEN_SIMULATION=ON \
  -DJEMALLOC_LIBRARIES=$HOME/opt/lib/libjemalloc.so \
  -DJEMALLOC_INCLUDE_DIRS=$HOME/opt/include && \
cmake --build software/build -j && \
cmake --install software/build && \
cd /local/home/smalinin/oasis/extension && \
export CMAKE_PREFIX_PATH=$HOME/opt:$CMAKE_PREFIX_PATH && \
export LD_LIBRARY_PATH=$HOME/opt/lib:$HOME/opt/lib64:$LD_LIBRARY_PATH && \
make clean && make EXT_FLAGS="-DEN_SIMULATION=ON" -j

module load vivado/2024.2
export COYOTE_SIM_DIR=/local/home/smalinin/oasis/hardware/build-sim
export LD_LIBRARY_PATH=$HOME/opt/lib:$HOME/opt/lib64:$LD_LIBRARY_PATH

./setup_simulation.sh