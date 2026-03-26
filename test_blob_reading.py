#!/usr/bin/env python3

import subprocess
import os
import tempfile
import zlib

def run_command(cmd, cwd=None):
    """Run a command and return stdout, stderr, and return code"""
    result = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    return result.stdout, result.stderr, result.returncode

def test_blob_reading():
    """Test that we can read blob objects correctly"""
    
    with tempfile.TemporaryDirectory() as test_dir:
        print(f"Testing blob reading in: {test_dir}")
        
        # Initialize with git
        run_command("git init", test_dir)
        run_command("git config user.name 'Test User'", test_dir)
        run_command("git config user.email 'test@example.com'", test_dir)
        
        # Create test content
        test_content = "Hello, World!\nThis is a test file.\n"
        test_file = os.path.join(test_dir, "test.txt")
        with open(test_file, 'w') as f:
            f.write(test_content)
        
        # Add file with git
        run_command("git add test.txt", test_dir)
        
        # Get the blob hash from git
        stdout, stderr, rc = run_command("git rev-parse :test.txt", test_dir)
        if rc != 0:
            print(f"Failed to get blob hash: {stderr}")
            return False
        
        blob_hash = stdout.strip()
        print(f"Blob hash: {blob_hash}")
        
        # Check that the blob file exists
        blob_dir = blob_hash[:2]
        blob_file = blob_hash[2:]
        blob_path = os.path.join(test_dir, ".git", "objects", blob_dir, blob_file)
        
        if not os.path.exists(blob_path):
            print(f"✗ Blob file doesn't exist: {blob_path}")
            return False
        
        print(f"✓ Blob file exists: {blob_path}")
        
        # Read and decompress the blob
        with open(blob_path, 'rb') as f:
            compressed_data = f.read()
        
        try:
            decompressed_data = zlib.decompress(compressed_data)
            print(f"✓ Successfully decompressed blob ({len(compressed_data)} -> {len(decompressed_data)} bytes)")
            
            # Parse the git object format: "blob <size>\0<content>"
            null_pos = decompressed_data.find(b'\x00')
            if null_pos == -1:
                print("✗ No null terminator found in blob")
                return False
            
            header = decompressed_data[:null_pos].decode('utf-8')
            content = decompressed_data[null_pos + 1:].decode('utf-8')
            
            print(f"Blob header: '{header}'")
            print(f"Blob content: '{repr(content)}'")
            
            if content == test_content:
                print("✓ Blob content matches original file")
            else:
                print("✗ Blob content doesn't match original file")
                print(f"Expected: {repr(test_content)}")
                print(f"Got: {repr(content)}")
                return False
            
        except zlib.error as e:
            print(f"✗ Failed to decompress blob: {e}")
            # Maybe it's not compressed?
            try:
                data_str = compressed_data.decode('utf-8', errors='ignore')
                print(f"Raw data (maybe uncompressed): '{repr(data_str)}'")
            except:
                print("Raw data is not text")
            return False
        
        # Now test ziggit diff to see if it can read the blob content
        print("\n--- Testing ziggit diff (should read blob content) ---")
        
        # Modify the file to create a diff
        with open(test_file, 'w') as f:
            f.write(test_content + "Modified line\n")
        
        # Run ziggit diff
        ziggit_path = "/root/ziggit/zig-out/bin/ziggit"
        if os.path.exists(ziggit_path):
            stdout, stderr, rc = run_command(f"{ziggit_path} diff", test_dir)
            print(f"Ziggit diff (rc={rc}):")
            print(f"STDOUT: '{stdout}'")
            if stderr.strip():
                print(f"STDERR: '{stderr.strip()}'")
            
            # Check if the diff shows the original content (from blob)
            if test_content.strip() in stdout:
                print("✓ Ziggit diff shows blob content correctly")
            elif stdout.strip() == "":
                print("✗ Ziggit diff shows no output (getIndexedFileContent probably returning empty)")
            else:
                print("? Ziggit diff shows some output but original content not found")
        else:
            print("Ziggit binary not found")
        
        return True

if __name__ == "__main__":
    test_blob_reading()