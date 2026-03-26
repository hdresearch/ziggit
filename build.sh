#!/bin/bash
# Build wrapper to handle environment issues
export HOME=/tmp
export XDG_CACHE_HOME=/tmp

exec zig build "$@"