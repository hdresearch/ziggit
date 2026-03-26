# Ziggit Integration Tests

This directory contains integration tests for ziggit that focus on interoperability with git.

## Test Files

- `git_interop_test.zig` - Comprehensive integration test suite written in Zig
- `run_integration_tests.sh` - Standalone shell script test runner
- `*_test.zig` - Individual test modules for specific functionality

## Running Tests

### Shell Script Runner (Recommended)

The shell script runner is the easiest way to run integration tests:

```bash
./test/run_integration_tests.sh
```

This script:
- Automatically attempts to build ziggit if needed
- Falls back to git-only tests if ziggit build fails
- Tests critical git functionality that ziggit must be compatible with
- Validates status --porcelain and log --oneline formats (critical for bun)

### Zig Test Runner

To run the full Zig integration test suite:

```bash
zig build test
```

This requires a successful ziggit build and runs all test modules.

## Test Categories

### Git Interoperability Tests
- Git init → ziggit status
- Ziggit init → git log  
- Git add/commit → ziggit log
- Ziggit add/commit → git status
- Binary compatibility (git index → ziggit reads)
- Object format compatibility
- Status --porcelain compatibility
- Log --oneline compatibility
- Packed object handling
- Branch operations
- Diff operations
- Checkout operations

### Additional Test Scenarios
- Multi-file staging scenarios
- Subdirectory operations
- Large file handling  
- Empty repository edge cases

## Test Environment

Tests create temporary directories under `/tmp/ziggit_integration_tests_*` and automatically clean up after completion.

Git configuration is set up automatically for tests with:
- `user.name = "Test User"`
- `user.email = "test@example.com"`

## CI/CD Integration

The shell script runner (`run_integration_tests.sh`) is designed to work in CI environments and provides clear pass/fail status codes.