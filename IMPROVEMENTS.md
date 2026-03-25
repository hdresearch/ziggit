# Ziggit Improvements

## Recent Enhancements

### Empty Commit Message Validation (2026-03-25)

**Problem**: Ziggit previously allowed empty commit messages while git rejects them, leading to compatibility issues.

**Solution**: Added proper validation in `cmdCommit` function to:
- Detect empty commit messages (`""`)
- Detect whitespace-only commit messages (`"   "`, `"\t\n"`, etc.)
- Return proper exit code (1) matching git behavior
- Display appropriate error message: "Aborting commit due to empty commit message."

**Impact**: 
- Improved git compatibility test results
- Fixed test case "commit with empty message" from ⚠ to ✓
- Better matches standard git behavior for commit message validation

**Code Changes**:
- Enhanced `cmdCommit` in `src/main_common.zig` with trim-based validation
- Added proper error messaging matching git's format
- Maintains backwards compatibility for valid commit messages

**Testing**:
- Verified empty messages are rejected with exit code 1
- Verified whitespace-only messages are rejected
- Verified valid messages still work correctly
- All existing tests continue to pass

This improvement ensures ziggit provides a true drop-in replacement experience for git commit functionality.