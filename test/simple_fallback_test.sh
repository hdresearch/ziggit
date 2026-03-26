#!/bin/bash

# Simple test for git fallback functionality

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ZIGGIT_BIN="${ZIGGIT_BIN:-$PROJECT_DIR/zig-out/bin/ziggit}"
TEST_DIR="/tmp/ziggit_simple_test_$$"

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "Testing git fallback functionality with $ZIGGIT_BIN"

# Setup test repo
echo "Setting up test repository..."
rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR"
cd "$TEST_DIR"

git init -q
git config user.name "Test User"
git config user.email "test@example.com"
echo "test content" > test.txt
git add test.txt
git commit -q -m "Initial commit"
git tag v1.0.0

echo -e "${YELLOW}Test repository created at $TEST_DIR${NC}"

# Test native commands
echo
echo "=== Testing Native Commands ==="

echo -n "ziggit status: "
if $ZIGGIT_BIN status >/dev/null 2>&1; then
    echo -e "${GREEN}PASS${NC}"
else
    echo -e "${RED}FAIL${NC}"
fi

echo -n "ziggit log --oneline -1: "
if $ZIGGIT_BIN log --oneline -1 | grep -q "Initial commit"; then
    echo -e "${GREEN}PASS${NC}"
else
    echo -e "${RED}FAIL${NC}"
fi

echo -n "ziggit branch: "
if $ZIGGIT_BIN branch | grep -q "master"; then
    echo -e "${GREEN}PASS${NC}"
else
    echo -e "${RED}FAIL${NC}"
fi

echo -n "ziggit tag: "
if $ZIGGIT_BIN tag | grep -q "v1.0.0"; then
    echo -e "${GREEN}PASS${NC}"
else
    echo -e "${RED}FAIL${NC}"
fi

# Test fallback commands  
echo
echo "=== Testing Fallback Commands ==="

echo -n "ziggit stash list: "
if $ZIGGIT_BIN stash list >/dev/null 2>&1; then
    echo -e "${GREEN}PASS${NC}"
else
    echo -e "${RED}FAIL${NC}"
fi

echo -n "ziggit remote -v: "
if $ZIGGIT_BIN remote -v >/dev/null 2>&1; then
    echo -e "${GREEN}PASS${NC}"
else
    echo -e "${RED}FAIL${NC}"
fi

echo -n "ziggit show HEAD: "
if $ZIGGIT_BIN show HEAD | grep -q "Initial commit"; then
    echo -e "${GREEN}PASS${NC}"
else
    echo -e "${RED}FAIL${NC}"
fi

echo -n "ziggit ls-files: "
if $ZIGGIT_BIN ls-files | grep -q "test.txt"; then
    echo -e "${GREEN}PASS${NC}"
else
    echo -e "${RED}FAIL${NC}"
fi

echo -n "ziggit cat-file -t HEAD: "
if $ZIGGIT_BIN cat-file -t HEAD | grep -q "commit"; then
    echo -e "${GREEN}PASS${NC}"
else
    echo -e "${RED}FAIL${NC}"
fi

echo -n "ziggit rev-list --count HEAD: "
if $ZIGGIT_BIN rev-list --count HEAD | grep -q "1"; then
    echo -e "${GREEN}PASS${NC}"
else
    echo -e "${RED}FAIL${NC}"
fi

echo -n "ziggit log --graph --oneline -5: "
if $ZIGGIT_BIN log --graph --oneline -5 >/dev/null 2>&1; then
    echo -e "${GREEN}PASS${NC}"
else
    echo -e "${RED}FAIL${NC}"
fi

echo -n "ziggit shortlog -sn -1: "
if $ZIGGIT_BIN shortlog -sn -1 >/dev/null 2>&1; then
    echo -e "${GREEN}PASS${NC}"
else
    echo -e "${RED}FAIL${NC}"
fi

# Clean up
echo
echo "Cleaning up..."
rm -rf "$TEST_DIR"

echo
echo -e "${GREEN}Simple fallback test completed${NC}"