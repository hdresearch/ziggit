#!/bin/bash
# Build libgit2 from source using zig cc.
# This is needed because libgit2-dev may not be available on all systems,
# and zig cc provides a portable C compiler.
#
# Usage: ./build_libgit2.sh [version]
#   version: libgit2 release tag (default: v1.8.4)

set -euo pipefail

VERSION="${1:-v1.8.4}"
LIBGIT2_SRC="/tmp/libgit2"
LIBGIT2_BUILD="/tmp/libgit2/build"

echo "=== Building libgit2 ${VERSION} with zig cc ==="

# Check prerequisites
command -v zig >/dev/null 2>&1 || { echo "ERROR: zig not found"; exit 1; }
command -v cmake >/dev/null 2>&1 || { echo "ERROR: cmake not found"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "ERROR: git not found"; exit 1; }

# Clone if needed
if [ ! -d "${LIBGIT2_SRC}" ]; then
    echo "Cloning libgit2 ${VERSION}..."
    git clone --depth 1 --branch "${VERSION}" \
        https://github.com/libgit2/libgit2.git "${LIBGIT2_SRC}"
else
    echo "Using existing libgit2 source at ${LIBGIT2_SRC}"
fi

# Fix zig cc compatibility: copy libgit2's regexp.h into xdiff deps
# so it's found before the system's deprecated <regexp.h>
if [ -f "${LIBGIT2_SRC}/src/util/regexp.h" ]; then
    cp "${LIBGIT2_SRC}/src/util/regexp.h" "${LIBGIT2_SRC}/deps/xdiff/regexp.h"
fi

# Create wrapper scripts for zig ar/ranlib (cmake needs standalone executables)
cat > /tmp/zig-ar.sh << 'AREOF'
#!/bin/sh
exec zig ar "$@"
AREOF
chmod +x /tmp/zig-ar.sh

cat > /tmp/zig-ranlib.sh << 'RNEOF'
#!/bin/sh
exec zig ranlib "$@"
RNEOF
chmod +x /tmp/zig-ranlib.sh

# Configure
mkdir -p "${LIBGIT2_BUILD}"
cd "${LIBGIT2_BUILD}"

echo "Configuring..."
CC="zig cc -target x86_64-linux-gnu" \
cmake .. \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_AR="/tmp/zig-ar.sh" \
    -DCMAKE_RANLIB="/tmp/zig-ranlib.sh" \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TESTS=OFF \
    -DBUILD_CLI=OFF \
    -DUSE_SSH=OFF \
    -DUSE_HTTPS=OFF \
    -DUSE_BUNDLED_ZLIB=ON \
    -DUSE_HTTP_PARSER=builtin \
    -DREGEX_BACKEND=builtin

# Build
echo "Building..."
make -j"$(nproc)"

echo ""
echo "=== libgit2 built successfully ==="
echo "Static library: ${LIBGIT2_BUILD}/libgit2.a"
echo "Headers: ${LIBGIT2_SRC}/include/"
