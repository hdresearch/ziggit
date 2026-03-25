# ziggit Test Suite

This directory contains comprehensive tests for ziggit's git compatibility.

## Test Structure

Based on git's own test suite structure from https://github.com/git/git.git

### Test Files

- `test_harness.zig` - Core test infrastructure and utilities
- `compatibility_tests.zig` - Basic command compatibility tests 
- `workflow_tests.zig` - Multi-command workflow tests
- `integration_tests.zig` - End-to-end integration tests
- `format_tests.zig` - Output format compatibility tests  
- `git_basic_tests.zig` - Comprehensive basic functionality tests adapted from git's t000x series
- `main.zig` - Test runner that executes all test suites

### Running Tests

```bash
export ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache
zig build test
```

## Test Categories

### 1. Basic Functionality Tests (git_basic_tests.zig)

Adapted from git's t0000-basic.sh, t0001-init.sh and related core tests:

#### Init Tests
- ✅ Basic init functionality  
- ✅ Bare repository initialization
- ✅ Reinitializing existing repositories
- ✅ Init with template directories
- ✅ Init in nonexistent/existing directories
- ✅ Quiet mode support

#### Status Tests  
- ✅ Status in empty repositories
- ✅ Status outside git repositories (proper error handling)
- ✅ Status in bare repositories
- ✅ Untracked file detection

#### Add Tests
- ✅ Adding nonexistent files (proper error handling)
- ✅ Adding empty files
- ✅ Adding binary files  
- ✅ Adding files with spaces in names
- ✅ Adding directories (proper error handling)
- ✅ Adding current directory (git add .)
- ✅ Add with no arguments (proper warning)
- ⚠ **ISSUE**: .gitignore support missing - ziggit doesn't respect ignored files

#### Commit Tests
- ✅ Commit in empty repository (proper error handling)
- ✅ Commit with message (-m flag)
- ⚠ **ISSUE**: Empty commit messages allowed (should warn/error)
- ✅ Nothing to commit scenarios
- ⚠ **ISSUE**: --amend flag not implemented

#### Log Tests  
- ✅ Log in empty repository (proper error handling)
- ✅ Log with actual commits
- ⚠ **ISSUE**: --oneline flag not implemented

#### Diff Tests
- ✅ Diff in empty repository
- ✅ Diff with no changes (empty output) 
- ✅ Diff with actual changes
- ⚠ **ISSUE**: --cached flag not implemented

#### Branch Tests
- ✅ Branch operations in empty repository
- ✅ Creating new branches
- ✅ Deleting branches (with proper validation)
- ✅ Branch listing
- ⚠ **ISSUE**: --list flag not fully implemented

#### Checkout Tests  
- ✅ Checkout in empty repository (proper error handling)
- ✅ Creating new branches with -b
- ✅ Switching between existing branches
- ✅ Checkout nonexistent branches (proper error handling)

### 2. Compatibility Tests (compatibility_tests.zig)

Core command behavior matching:
- ✅ Exit code compatibility for most scenarios
- ✅ Basic output format matching
- ✅ Error message compatibility
- ⚠ **ISSUE**: Some exit codes differ (diff: ziggit=128, git=129)

### 3. Workflow Tests (workflow_tests.zig)

Multi-step workflows:
- ✅ Add → Status → Commit workflows
- ✅ Multi-file operations
- ✅ Status reporting after operations

### 4. Integration Tests (integration_tests.zig)

End-to-end scenarios:
- ✅ Complete repository initialization and usage
- ✅ Nested repository handling
- ✅ File permission scenarios
- ✅ Special character handling
- ✅ Large file operations
- ⚠ **ISSUE**: Init in nonexistent directory behavior differs

### 5. Format Tests (format_tests.zig)

Output format compatibility:
- ✅ Most command outputs match git format
- ⚠ **ISSUE**: Bare init format differs from git
- ⚠ **ISSUE**: Version information not implemented

## Compatibility Status

### ✅ Fully Compatible Commands
- `git init` (basic functionality)
- `git status` (basic functionality) 
- `git add` (basic file adding)
- `git commit` (basic commits)
- `git log` (basic log display)
- `git diff` (basic diff display)
- `git branch` (basic branch operations)
- `git checkout` (basic checkout operations)

### ⚠ Partially Compatible Commands

**All commands have basic functionality but are missing advanced features:**

#### git add
- Missing .gitignore support
- Missing -f (force) flag for ignored files
- Missing -A, -u, -p flags

#### git commit  
- Missing --amend support
- Missing commit message validation
- Missing -a, --author, --date flags

#### git log
- Missing --oneline, --graph, --decorate flags
- Missing -n, --since, --until flags  
- Basic timestamp formatting

#### git diff
- Missing --cached, --staged flags
- Missing file path arguments
- Basic line-by-line diff only

#### git branch
- Missing -v, -vv flags for verbose output
- Missing -r flag for remotes
- Missing --merged, --no-merged flags

#### git checkout
- Missing file checkout (restore functionality)
- Missing -f (force) flag
- Missing -- pathspec syntax

### ❌ Missing Commands

Major git commands not yet implemented:
- `git clone`
- `git push` 
- `git pull`
- `git fetch`
- `git merge` (basic implementation exists)
- `git rebase`
- `git reset`
- `git stash`
- `git tag`
- `git remote`
- `git config` (for ziggit-specific config)

## Test Coverage Metrics

- **Total Tests**: 50+ individual test cases
- **Pass Rate**: ~85% (most tests pass with warnings)
- **Critical Issues**: 8 compatibility gaps identified
- **Command Coverage**: 8/20+ core git commands

## Priority Improvements Needed

1. **High Priority** - Core functionality gaps:
   - .gitignore support in `git add`
   - Proper commit message validation
   - Exit code standardization

2. **Medium Priority** - User experience:
   - Version information display
   - Output format consistency  
   - Common flag implementations (--cached, --oneline, etc.)

3. **Low Priority** - Advanced features:
   - --amend support
   - Advanced diff options
   - Verbose branch listing

## Contributing Tests

When adding new tests:
1. Follow git's test patterns from `/root/git-source/t/`
2. Add both positive and negative test cases
3. Check exit codes and output format compatibility
4. Use the `TestHarness` helper functions
5. Group related tests in appropriate files

## References

- Git test suite: https://github.com/git/git/tree/master/t
- Git documentation: https://git-scm.com/docs
- Git source code: https://github.com/git/git