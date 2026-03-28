#!/bin/bash
cd /root/ziggit
zig build 2>&1
# Fix: zig build creates wrapper scripts, we need the actual ELF binary
LATEST=$(ls -t .zig-cache/o/*/ziggit 2>/dev/null | head -1)
if [ -n "$LATEST" ] && head -c 4 "$LATEST" | grep -q ELF; then
    cp "$LATEST" zig-out/bin/ziggit
    chmod +x zig-out/bin/ziggit
    ln -sf ziggit zig-out/bin/git
fi
