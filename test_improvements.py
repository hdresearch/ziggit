#!/usr/bin/env python3

import subprocess
import os
import tempfile

def run_command(cmd, cwd=None):
    """Run a command and return stdout, stderr, and return code"""
    result = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    return result.stdout, result.stderr, result.returncode

def test_comprehensive_improvements():
    """Test all the improvements made to ziggit"""
    
    with tempfile.TemporaryDirectory() as test_dir:
        print(f"Testing improvements in: {test_dir}")
        
        # Initialize repository
        run_command("git init", test_dir)
        run_command("git config user.name 'Test User'", test_dir)
        run_command("git config user.email 'test@example.com'", test_dir)
        
        ziggit_path = "/root/ziggit/zig-out/bin/ziggit"
        
        print("=== TEST 1: Basic blob content reading ===")
        # Test getIndexedFileContent functionality
        test_content = "Line 1\nLine 2\nLine 3\n"
        with open(os.path.join(test_dir, "test.txt"), 'w') as f:
            f.write(test_content)
        
        run_command(f"{ziggit_path} add test.txt", test_dir)
        
        # Modify file to create diff
        with open(os.path.join(test_dir, "test.txt"), 'w') as f:
            f.write(test_content + "Line 4\n")
        
        stdout, stderr, rc = run_command(f"{ziggit_path} diff", test_dir)
        print(f"Diff result (rc={rc}): {len(stdout)} chars of output")
        if "Line 1" in stdout and "Line 2" in stdout:
            print("✓ getIndexedFileContent working - shows original content in diff")
        else:
            print("✗ getIndexedFileContent issue - original content not in diff")
        
        print("\n=== TEST 2: Index format compatibility ===")
        # Create complex index scenario
        os.makedirs(os.path.join(test_dir, "subdir"))
        with open(os.path.join(test_dir, "subdir", "file.txt"), 'w') as f:
            f.write("Subdir content\n")
        
        run_command("git add .", test_dir)
        stdout, stderr, rc = run_command(f"{ziggit_path} status", test_dir)
        if rc == 0 and "subdir/file.txt" in stdout:
            print("✓ Index format compatibility working")
        else:
            print("✗ Index format compatibility issue")
        
        print("\n=== TEST 3: Initial commit and merge setup ===")
        # Create initial commit
        run_command(f"{ziggit_path} commit -m 'Initial commit'", test_dir)
        
        # Create branch for merge test
        run_command(f"{ziggit_path} branch feature", test_dir)
        run_command(f"{ziggit_path} checkout feature", test_dir)
        
        # Modify on feature branch
        with open(os.path.join(test_dir, "test.txt"), 'w') as f:
            f.write("Feature line 1\nLine 2\nLine 3\nFeature line 4\n")
        
        run_command(f"{ziggit_path} add test.txt", test_dir)
        run_command(f"{ziggit_path} commit -m 'Feature changes'", test_dir)
        
        # Switch to master and make conflicting changes
        run_command(f"{ziggit_path} checkout master", test_dir)
        with open(os.path.join(test_dir, "test.txt"), 'w') as f:
            f.write("Master line 1\nLine 2\nLine 3\nMaster line 4\n")
        
        run_command(f"{ziggit_path} add test.txt", test_dir)
        run_command(f"{ziggit_path} commit -m 'Master changes'", test_dir)
        
        print("\n=== TEST 4: Enhanced 3-way merge ===")
        stdout, stderr, rc = run_command(f"{ziggit_path} merge feature", test_dir)
        print(f"Merge result (rc={rc})")
        if rc != 0:
            # Check conflict resolution
            with open(os.path.join(test_dir, "test.txt"), 'r') as f:
                content = f.read()
            if "<<<<<<< HEAD" in content and "=======" in content and ">>>>>>> " in content:
                print("✓ Enhanced 3-way merge with proper conflict markers")
            else:
                print("✗ 3-way merge conflict markers missing")
        else:
            print("✓ 3-way merge completed without conflicts")
        
        print("\n=== TEST 5: Pack file support ===")
        # Reset to clean state and create many commits
        run_command("git reset --hard HEAD~1", test_dir)  # Remove merge conflicts
        
        # Create multiple commits to trigger pack file creation
        for i in range(5):
            with open(os.path.join(test_dir, f"pack_file_{i}.txt"), 'w') as f:
                f.write(f"Pack file content {i}\n")
            run_command("git add .", test_dir)
            run_command(f"git commit -m 'Pack commit {i}'", test_dir)
        
        # Force pack file creation
        run_command("git gc --aggressive", test_dir)
        
        # Test if ziggit can read from pack files
        stdout, stderr, rc = run_command(f"{ziggit_path} log --oneline", test_dir)
        print(f"Log with pack files (rc={rc}): {len(stdout.strip().split() if stdout.strip() else [])} commits")
        
        if rc == 0 and stdout.strip():
            log_lines = len([line for line in stdout.strip().split('\n') if line.strip()])
            if log_lines >= 5:
                print("✓ Pack file support improved - can read commits from pack files")
            else:
                print(f"? Pack file support partial - only {log_lines} commits readable")
        else:
            print("✗ Pack file support still broken - cannot read packed commits")
        
        print("\n=== TEST 6: Checkout with tree walking ===")
        # Test checkout functionality
        run_command(f"{ziggit_path} branch test-checkout", test_dir)
        stdout, stderr, rc = run_command(f"{ziggit_path} checkout test-checkout", test_dir)
        
        if rc == 0:
            print("✓ Checkout with tree walking successful")
            
            # Check if files are properly restored
            expected_files = [f"pack_file_{i}.txt" for i in range(5)]
            existing_files = [f for f in os.listdir(test_dir) if f.startswith("pack_file_")]
            
            if len(existing_files) == len(expected_files):
                print("✓ Working tree properly restored from commit")
            else:
                print(f"? Working tree partially restored ({len(existing_files)}/{len(expected_files)} files)")
        else:
            print("✗ Checkout with tree walking failed")
        
        print("\n=== SUMMARY ===")
        print("Improvements tested:")
        print("1. getIndexedFileContent() blob reading")
        print("2. Index format binary compatibility") 
        print("3. Enhanced 3-way merge with better conflict resolution")
        print("4. Improved pack file reading support")
        print("5. Better checkout with proper tree walking")
        
        return True

if __name__ == "__main__":
    test_comprehensive_improvements()