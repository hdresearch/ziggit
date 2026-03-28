#!/bin/sh
# Fix zig build wrapper script issue
DEST="/root/ziggit/zig-out/bin/ziggit"
BEST=$(find /root/ziggit/.zig-cache/o -name ziggit -size +1M 2>/dev/null | xargs ls -t 2>/dev/null | head -1)
if [ -n "$BEST" ]; then
    rm -f "$DEST"
    cp "$BEST" "$DEST"
    chmod +x "$DEST"
fi
# Fix symlink
rm -f /root/ziggit/zig-out/bin/git
ln -sf ziggit /root/ziggit/zig-out/bin/git
