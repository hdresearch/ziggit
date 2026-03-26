#!/usr/bin/env python3

import subprocess
import os
import tempfile

def run_command(cmd, cwd=None):
    """Run a command and return stdout, stderr, and return code"""
    result = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    return result.stdout, result.stderr, result.returncode

def test_merge_functionality():
    """Test ziggit merge functionality"""
    
    with tempfile.TemporaryDirectory() as test_dir:
        print(f"Testing merge functionality in: {test_dir}")
        
        # Initialize with git and ziggit
        run_command("git init", test_dir)
        run_command("git config user.name 'Test User'", test_dir)
        run_command("git config user.email 'test@example.com'", test_dir)
        
        # Create initial commit using ziggit
        test_file = os.path.join(test_dir, "test.txt")
        with open(test_file, 'w') as f:
            f.write("Line 1\nLine 2\nLine 3\n")
        
        ziggit_path = "/root/ziggit/zig-out/bin/ziggit"
        
        # Add and commit with ziggit
        stdout, stderr, rc = run_command(f"{ziggit_path} add test.txt", test_dir)
        print(f"Ziggit add (rc={rc}): {stdout.strip()}")
        if stderr.strip():
            print(f"Add stderr: {stderr.strip()}")
        
        stdout, stderr, rc = run_command(f"{ziggit_path} commit -m 'Initial commit'", test_dir)
        print(f"Ziggit commit (rc={rc}): {stdout.strip()}")
        if stderr.strip():
            print(f"Commit stderr: {stderr.strip()}")
        
        if rc != 0:
            print("Failed to create initial commit with ziggit, skipping merge test")
            return False
        
        print("✓ Initial commit created with ziggit")
        
        # Create a branch using ziggit
        stdout, stderr, rc = run_command(f"{ziggit_path} branch feature", test_dir)
        print(f"Ziggit branch (rc={rc}): {stdout.strip()}")
        if rc != 0:
            print("Failed to create branch with ziggit")
            return False
        
        # Switch to feature branch
        stdout, stderr, rc = run_command(f"{ziggit_path} checkout feature", test_dir)
        print(f"Ziggit checkout (rc={rc}): {stdout.strip()}")
        if rc != 0:
            print("Failed to checkout branch with ziggit")
            return False
        
        print("✓ Created and switched to feature branch")
        
        # Modify file on feature branch
        with open(test_file, 'w') as f:
            f.write("Line 1 modified\nLine 2\nLine 3\nNew line 4\n")
        
        # Commit changes on feature branch
        run_command(f"{ziggit_path} add test.txt", test_dir)
        stdout, stderr, rc = run_command(f"{ziggit_path} commit -m 'Feature changes'", test_dir)
        print(f"Feature commit (rc={rc}): {stdout.strip()}")
        
        # Switch back to master
        run_command(f"{ziggit_path} checkout master", test_dir)
        
        # Modify file on master (create conflict scenario)
        with open(test_file, 'w') as f:
            f.write("Line 1 different\nLine 2\nLine 3\nMaster line 4\n")
        
        run_command(f"{ziggit_path} add test.txt", test_dir)
        stdout, stderr, rc = run_command(f"{ziggit_path} commit -m 'Master changes'", test_dir)
        print(f"Master commit (rc={rc}): {stdout.strip()}")
        
        print("✓ Set up merge scenario with potential conflict")
        
        # Now attempt merge with ziggit
        print("\n--- Testing ziggit merge ---")
        stdout, stderr, rc = run_command(f"{ziggit_path} merge feature", test_dir)
        print(f"Ziggit merge (rc={rc}):")
        print(f"STDOUT: '{stdout.strip()}'")
        if stderr.strip():
            print(f"STDERR: '{stderr.strip()}'")
        
        # Check the result
        if rc == 0:
            print("✓ Merge completed successfully")
            
            # Check if working tree was updated
            with open(test_file, 'r') as f:
                merged_content = f.read()
            print(f"Merged file content:\n{repr(merged_content)}")
            
            # Check git log to see if merge commit was created
            stdout, stderr, rc = run_command("git log --oneline", test_dir)
            print(f"Git log after merge:\n{stdout}")
            
        elif "conflict" in stdout.lower() or "conflict" in stderr.lower():
            print("✓ Merge detected conflicts correctly")
            
            # Check if conflict markers were created
            with open(test_file, 'r') as f:
                conflict_content = f.read()
            print(f"Conflict file content:\n{repr(conflict_content)}")
            
            if "<<<<<<< HEAD" in conflict_content and "=======" in conflict_content and ">>>>>>> " in conflict_content:
                print("✓ Proper conflict markers created")
            else:
                print("✗ No proper conflict markers found")
        else:
            print("? Merge had unexpected result")
        
        # Test checkout functionality (tree walking)
        print("\n--- Testing checkout tree functionality ---")
        
        # Create a new branch and test checkout
        run_command(f"{ziggit_path} branch test-checkout", test_dir)
        stdout, stderr, rc = run_command(f"{ziggit_path} checkout test-checkout", test_dir)
        print(f"Checkout test branch (rc={rc}): {stdout.strip()}")
        
        # Check if working tree matches the commit
        if rc == 0:
            print("✓ Branch checkout successful")
        else:
            print("✗ Branch checkout failed")
        
        return True

if __name__ == "__main__":
    test_merge_functionality()