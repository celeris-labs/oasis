#!/bin/bash -ex

# Determine the paths to install into
download_path="$HOME/download"
if [ -n "$DOWNLOAD_PATH" ]; then
  download_path="$DOWNLOAD_PATH"
fi
mkdir -p "${download_path}"

install_path="$HOME/opt"
if [ -n "$INSTALL_PATH" ]; then
  install_path="$INSTALL_PATH"
fi
mkdir -p "${install_path}"

echo "Downloading into ${download_path} and installing into ${install_path}"

arrow_version="24.0.0"
arrow_archive="apache-arrow-${arrow_version}.tar.gz"
arrow_url="https://github.com/apache/arrow/releases/download/apache-arrow-${arrow_version}/${arrow_archive}"

pushd "${download_path}"

# Download the release tarball and its SHA-256 checksum
wget "${arrow_url}"
wget "${arrow_url}.sha256"

# Verify the checksum
sha256sum -c "${arrow_archive}.sha256"

# Extract the archive
tar -xzf "${arrow_archive}"
rm "${arrow_archive}" "${arrow_archive}.sha256"

pushd "apache-arrow-${arrow_version}/cpp"

mkdir -p build-release
cd build-release

# Configure the compilation
# CMAKE_INSTALL_PREFIX:  Install path
cmake -DCMAKE_INSTALL_PREFIX=${install_path} ..

# Compile & Install (adjust -j to your number of CPU cores)
make -j8
make install

# Go back to the parent directory
popd
popd