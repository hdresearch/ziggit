# Ziggit Git Compatibility Test Suite

This directory contains a comprehensive test suite designed to verify that ziggit functions as a drop-in replacement for git. The tests are inspired by and adapted from the official git source test suite (`git/git.git/t/`).

## Overview

The test suite verifies compatibility across core git operations:
- Repository initialization (`git init`)
- File staging (`git add`)  
- Commit creation (`git commit`)
- Branch management (`git branch`)
- Commit history (`git log`)
- Change visualization (`git diff`)
- Working tree status (`git status`)

## Architecture

### Test Framework (`git_source_test_adapter.zig`)
A Zig-native test harness that provides:
- Isolated test environments (temporary directories)
- Process spawning for ziggit and git commands
- Output comparison and validation
- Error code verification
- Structured test result reporting

### Test Suites

Each test suite follows the naming convention `tXXXX_*_tests.zig` inspired by git's test organization:

| File | Test Suite | Coverage |
|------|------------|----------|
| `t0001_init_tests.zig` | Repository Initialization | `git init`, bare repos, existing directories |
| `t2000_add_tests.zig` | File Staging | `git add`, glob patterns, error handling |
| `t3000_commit_tests.zig` | Commit Creation | `git commit`, messages, SHA generation |
| `t3200_branch_tests.zig` | Branch Management | `git branch`, create, delete, rename |
| `t4000_log_tests.zig` | Commit History | `git log`, formatting, filtering |
| `t4001_diff_tests.zig` | Change Visualization | `git diff`, staged/unstaged, formats |
| `t7000_status_tests.zig` | Working Tree Status | `git status`, porcelain, change detection |

### Test Runners

- `git_compatibility_main.zig` - Basic test runner for core operations
- `comprehensive_test_runner.zig` - Complete test suite with detailed reporting

## Usage

### Prerequisites

1. Ensure ziggit is built:
   ```bash
   cd /root/ziggit
   export ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache
   zig build
   ```

2. Verify the binary exists at `/root/ziggit/zig-out/bin/ziggit`

### Running Tests

#### Individual Test Suites
```bash
# Run specific test suite
zig run test/t0001_init_tests.zig

# Run with specific allocator debugging
zig run test/t0001_init_tests.zig --debug
```

#### Complete Test Suite
```bash
# Run all compatibility tests
zig run test/git_compatibility_main.zig

# Run comprehensive suite with detailed reporting
zig run test/comprehensive_test_runner.zig
```

#### Build System Integration
```bash
# Run via build system (if integrated)
zig build test-compat
```

## Test Structure

Each test case follows this pattern:

```zig
fn testFeature(runner: *TestRunner) !TestResult {
    // Setup test scenario
    try runner.createFile("test.txt", "content");
    
    // Execute command
    const result = try runner.runZiggit(&[_][]const u8{"command", "args"});
    defer result.deinit(runner.allocator);
    
    // Verify behavior
    if (runner.expectExitCode(0, result.exit_code, "description") == .fail) return .fail;
    if (runner.expectContains(result.stdout, "expected", "description") == .fail) return .fail;
    
    return .pass;
}
```

## Compatibility Testing Strategy

### 1. Behavior Verification
- Command success/failure matches git
- Exit codes match git conventions
- Error messages are appropriate

### 2. Output Format Compatibility
- Standard output format matches git
- Porcelain formats for machine parsing
- Human-readable formats for interactive use

### 3. Side Effects Verification
- File system changes match expectations
- Repository state changes correctly
- Configuration handling

### 4. Edge Cases
- Empty repositories
- Invalid inputs
- Boundary conditions
- Error recovery

## Current Limitations

### Test Framework Issues
The test framework currently has process spawning issues that prevent proper execution of ziggit commands. This needs to be resolved for full test functionality.

### Areas for Improvement
1. **Process Execution**: Fix FileNotFound errors when spawning ziggit
2. **Memory Management**: Eliminate memory leaks in test harness
3. **Error Handling**: Improve test failure diagnostics
4. **Performance**: Add timing measurements for benchmarking

## Extending the Test Suite

### Adding New Tests

1. Create a new test file following naming convention
2. Implement test cases using the TestRunner framework
3. Add to the comprehensive test runner
4. Update this documentation

### Test Case Best Practices

- Use descriptive test names
- Include both positive and negative test cases
- Test edge cases and error conditions
- Compare behavior directly with git when possible
- Include setup and cleanup functions
- Document expected behavior

### Git Source Adaptation

When adapting tests from git source (`git/git.git/t/`):
1. Understand the original test intent
2. Translate shell script logic to Zig
3. Maintain the same test coverage
4. Adapt assertions to Zig test framework
5. Preserve test naming and organization

## Contributing

When contributing to the test suite:

1. Follow existing code style and patterns
2. Add comprehensive test coverage for new features
3. Update documentation as needed
4. Ensure tests pass before submitting
5. Include compatibility verification with git

## Git Source Test Organization

This test suite is organized similarly to git's test directory:

- `t0xxx` - Basic git functionality
- `t1xxx` - Plumbing commands  
- `t2xxx` - Porcelain commands (add, etc.)
- `t3xxx` - Advanced porcelain (branch, commit, etc.)
- `t4xxx` - History/diff commands
- `t5xxx` - Remote operations
- `t6xxx` - Advanced features
- `t7xxx` - User interface commands
- `t8xxx` - Performance tests
- `t9xxx` - Integration tests

## Future Enhancements

### Planned Test Suites
- `t1000_checkout_tests.zig` - Branch switching and file checkout
- `t5000_merge_tests.zig` - Branch merging functionality  
- `t5100_remote_tests.zig` - Remote repository operations
- `t6000_advanced_tests.zig` - Rebase, cherry-pick, stash
- `t8000_performance_tests.zig` - Performance benchmarking
- `t9000_integration_tests.zig` - Real-world workflow testing

### Framework Enhancements
- Parallel test execution
- Test result caching
- Benchmark integration
- CI/CD integration
- Coverage reporting

This test suite provides a solid foundation for ensuring ziggit's compatibility with git and can be extended to cover additional functionality as ziggit development progresses.