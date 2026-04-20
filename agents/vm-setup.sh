#!/bin/bash
set -ex

# Add swap (2GB)
if [ ! -f /swapfile ]; then
    dd if=/dev/zero of=/swapfile bs=1M count=2048
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo "/swapfile none swap sw 0 0" >> /etc/fstab
fi
swapon /swapfile 2>/dev/null || true

# Install Node.js
if ! command -v node &> /dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    apt-get install -y nodejs
fi

# Install git and xz
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq git xz-utils

# Install pi
if ! command -v pi &> /dev/null; then
    npm install -g @mariozechner/pi-coding-agent
fi

# Install zig
if [ ! -f /usr/local/bin/zig ]; then
    cd /root
    curl -sL -o zig.tar.xz https://ziglang.org/download/0.13.0/zig-linux-x86_64-0.13.0.tar.xz
    tar xf zig.tar.xz
    rm -rf /usr/local/zig
    mv zig-linux-x86_64-0.13.0 /usr/local/zig
    ln -sf /usr/local/zig/zig /usr/local/bin/zig
    rm -f zig.tar.xz
fi

# Clone repo
if [ ! -d /root/ziggit ]; then
    . /etc/environment
    git clone "https://x-access-token:${GITHUB_API_KEY}@github.com/hdresearch/ziggit.git" /root/ziggit
    cd /root/ziggit
    git config user.email "agent@hdresearch.com"
    git config user.name "ziggit-agent"
fi

echo "=== SETUP VERIFICATION ==="
which node pi git zig
free -h
ls /root/ziggit/
echo "=== DONE ==="
