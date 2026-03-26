#!/usr/bin/env python3

import subprocess
import os
import tempfile
import shutil

def run_command(cmd, cwd=None):
    """Run a command and return stdout, stderr, and return code"""
    result = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    return result.stdout, result.stderr, result.returncode

def test_basic_git_operations():
    """Test basic git operations that ziggit should support"""
    
    # Create a temporary directory for testing
    with tempfile.TemporaryDirectory() as test_dir:
        print(f"Testing in: {test_dir}")
        
        # Initialize with git
        stdout, stderr, rc = run_command("git init", test_dir)
        if rc != 0:
            print(f"git init failed: {stderr}")
            return False
        print("✓ git init successful")
        
        # Configure git
        run_command("git config user.name 'Test User'", test_dir)
        run_command("git config user.email 'test@example.com'", test_dir)
        
        # Create a test file
        test_file = os.path.join(test_dir, "test.txt")
        with open(test_file, 'w') as f:
            f.write("Hello, World!\n")
        
        # Add file with git
        stdout, stderr, rc = run_command("git add test.txt", test_dir)
        if rc != 0:
            print(f"git add failed: {stderr}")
            return False
        print("✓ git add successful")
        
        # Check git status
        stdout, stderr, rc = run_command("git status --porcelain", test_dir)
        print(f"Git status: '{stdout.strip()}'")
        
        # Now try to read with ziggit if it exists
        ziggit_path = "/root/ziggit/zig-out/bin/ziggit"
        if os.path.exists(ziggit_path):
            stdout, stderr, rc = run_command(f"{ziggit_path} status", test_dir)
            print(f"Ziggit status (rc={rc}): '{stdout.strip()}'")
            if stderr.strip():
                print(f"Ziggit stderr: '{stderr.strip()}'")
        else:
            print("Ziggit binary not found - need to build first")
        
        # Check the index file exists and has correct format
        index_path = os.path.join(test_dir, ".git", "index")
        if os.path.exists(index_path):
            with open(index_path, 'rb') as f:
                header = f.read(12)
                if len(header) >= 4:
                    signature = header[:4]
                    print(f"Index signature: {signature}")
                    if signature == b'DIRC':
                        print("✓ Index has correct DIRC signature")
                        if len(header) >= 12:
                            version = int.from_bytes(header[4:8], 'big')
                            entry_count = int.from_bytes(header[8:12], 'big')
                            print(f"Index version: {version}, entries: {entry_count}")
                    else:
                        print(f"✗ Index has wrong signature: {signature}")
                else:
                    print("✗ Index file too small")
        else:
            print("✗ Index file doesn't exist")
        
        # Check objects directory structure
        objects_dir = os.path.join(test_dir, ".git", "objects")
        if os.path.exists(objects_dir):
            print("✓ Objects directory exists")
            
            # List all object files
            for root, dirs, files in os.walk(objects_dir):
                for file in files:
                    if len(file) == 38:  # Object files are 38 chars (40 - 2 for directory)
                        rel_path = os.path.relpath(os.path.join(root, file), objects_dir)
                        obj_hash = rel_path.replace('/', '')
                        print(f"Found object: {obj_hash}")
        else:
            print("✗ Objects directory doesn't exist")
        
        return True

if __name__ == "__main__":
    test_basic_git_operations()