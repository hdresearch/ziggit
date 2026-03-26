#!/usr/bin/env python3

import subprocess
import os
import tempfile

def run_command(cmd, cwd=None):
    """Run a command and return stdout, stderr, and return code"""
    result = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    return result.stdout, result.stderr, result.returncode

def test_pack_file_support():
    """Test ziggit's ability to read pack files"""
    
    with tempfile.TemporaryDirectory() as test_dir:
        print(f"Testing pack file support in: {test_dir}")
        
        # Initialize repository
        run_command("git init", test_dir)
        run_command("git config user.name 'Test User'", test_dir)
        run_command("git config user.email 'test@example.com'", test_dir)
        
        # Create multiple commits to generate objects that can be packed
        for i in range(10):
            file_path = os.path.join(test_dir, f"file{i}.txt")
            with open(file_path, 'w') as f:
                f.write(f"Content of file {i}\n" * (i + 1))
            
            run_command(f"git add file{i}.txt", test_dir)
            run_command(f"git commit -m 'Commit {i}'", test_dir)
        
        print("✓ Created 10 commits with git")
        
        # Check objects before packing
        objects_dir = os.path.join(test_dir, ".git", "objects")
        loose_objects_before = []
        
        for root, dirs, files in os.walk(objects_dir):
            for file in files:
                if len(file) == 38 and root.endswith(objects_dir + "/" + file[:1]):
                    obj_hash = os.path.basename(root) + file
                    if len(obj_hash) == 40:
                        loose_objects_before.append(obj_hash)
        
        print(f"Found {len(loose_objects_before)} loose objects before packing")
        
        # Test ziggit functionality with loose objects first
        ziggit_path = "/root/ziggit/zig-out/bin/ziggit"
        stdout, stderr, rc = run_command(f"{ziggit_path} log --oneline", test_dir)
        if rc == 0:
            log_lines = len([line for line in stdout.strip().split('\n') if line.strip()])
            print(f"✓ Ziggit can read {log_lines} commits from loose objects")
        else:
            print(f"✗ Ziggit failed to read loose objects: {stderr}")
        
        # Now force git to create pack files
        print("\n--- Creating pack files ---")
        stdout, stderr, rc = run_command("git gc --aggressive", test_dir)
        if rc != 0:
            print(f"git gc failed: {stderr}")
            return False
        
        print("✓ git gc completed")
        
        # Check if pack files were created
        pack_dir = os.path.join(test_dir, ".git", "objects", "pack")
        pack_files = []
        idx_files = []
        
        if os.path.exists(pack_dir):
            for file in os.listdir(pack_dir):
                if file.endswith('.pack'):
                    pack_files.append(file)
                elif file.endswith('.idx'):
                    idx_files.append(file)
        
        print(f"Found {len(pack_files)} pack files and {len(idx_files)} index files")
        
        if len(pack_files) == 0:
            print("No pack files created, skipping pack file tests")
            return True
        
        # Check how many loose objects remain
        loose_objects_after = []
        for root, dirs, files in os.walk(objects_dir):
            for file in files:
                if len(file) == 38 and root.endswith(objects_dir + "/" + file[:1]):
                    obj_hash = os.path.basename(root) + file
                    if len(obj_hash) == 40:
                        loose_objects_after.append(obj_hash)
        
        print(f"Found {len(loose_objects_after)} loose objects after packing")
        
        # Test if ziggit can still read objects from pack files
        print("\n--- Testing ziggit with pack files ---")
        stdout, stderr, rc = run_command(f"{ziggit_path} log --oneline", test_dir)
        if rc == 0:
            log_lines = len([line for line in stdout.strip().split('\n') if line.strip()])
            print(f"✓ Ziggit can read {log_lines} commits from packed objects")
            
            if log_lines >= 10:
                print("✓ All commits accessible from pack files")
            else:
                print(f"✗ Some commits missing (expected 10, got {log_lines})")
        else:
            print(f"✗ Ziggit failed to read packed objects: {stderr}")
        
        # Test status with packed objects
        stdout, stderr, rc = run_command(f"{ziggit_path} status", test_dir)
        if rc == 0:
            print("✓ Ziggit status works with packed objects")
        else:
            print(f"✗ Ziggit status failed with packed objects: {stderr}")
        
        # Test diff with packed objects
        # Modify a file to create a diff
        with open(os.path.join(test_dir, "file9.txt"), 'a') as f:
            f.write("Modified line\n")
        
        stdout, stderr, rc = run_command(f"{ziggit_path} diff", test_dir)
        if rc == 0 and stdout.strip():
            print("✓ Ziggit diff works with packed objects")
            print(f"Diff preview: {stdout[:100]}...")
        else:
            print(f"✗ Ziggit diff failed with packed objects: {stderr}")
        
        # Test checkout with packed objects
        print("\n--- Testing checkout with packed objects ---")
        
        # Create a new branch and commit
        run_command("git checkout -b test-pack", test_dir)
        with open(os.path.join(test_dir, "pack_test.txt"), 'w') as f:
            f.write("Pack test file\n")
        run_command("git add pack_test.txt", test_dir)
        run_command("git commit -m 'Pack test commit'", test_dir)
        
        # Switch to master and then try to switch back with ziggit
        run_command("git checkout master", test_dir)
        stdout, stderr, rc = run_command(f"{ziggit_path} checkout test-pack", test_dir)
        
        if rc == 0:
            print("✓ Ziggit checkout works with packed objects")
            
            # Verify the file was restored
            pack_test_path = os.path.join(test_dir, "pack_test.txt")
            if os.path.exists(pack_test_path):
                with open(pack_test_path, 'r') as f:
                    content = f.read()
                if content.strip() == "Pack test file":
                    print("✓ File correctly restored from packed objects")
                else:
                    print("✗ File content incorrect after checkout")
            else:
                print("✗ File not restored after checkout")
        else:
            print(f"✗ Ziggit checkout failed with packed objects: {stderr}")
        
        return True

if __name__ == "__main__":
    test_pack_file_support()