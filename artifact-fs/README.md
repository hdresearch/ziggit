# Using ziggit with ArtifactFS

[ArtifactFS](https://github.com/cloudflare/artifact-fs) is Cloudflare's FUSE-based filesystem driver that mounts Git repositories as local working trees, hydrating file contents on demand. It's designed for agents, sandboxes, and short-lived environments where waiting for a full `git clone` is too expensive.

ArtifactFS works with **any Git remote** — not just Cloudflare Artifacts. You can use ziggit as a drop-in replacement for git when working with ArtifactFS.

## How ArtifactFS uses Git

ArtifactFS shells out to the `git` CLI binary. It does not link against libgit2 or any git library. The critical commands it uses are:

| Command | Purpose | ziggit support |
|---------|---------|----------------|
| `git clone --filter=blob:none --no-checkout --single-branch` | Blobless clone (fetches tree + refs, skips file contents) | ✅ |
| `git cat-file --batch` | On-demand blob hydration (persistent process) | ✅ |
| `git cat-file --batch-check --buffer` | Batch size resolution without network fetches | ✅ |
| `git ls-tree -r -t -z HEAD` | Full tree enumeration for snapshot indexing | ✅ |
| `git fetch origin` | Background ref updates | ✅ |
| `git rev-parse HEAD` | Resolve current HEAD | ✅ |
| `git symbolic-ref -q --short HEAD` | Detect branch name | ✅ |
| `git hash-object --no-filters` | Verify blob integrity | ✅ |
| `git read-tree HEAD` | Update index after HEAD changes | ✅ |
| `git rev-list --left-right --count` | Compute ahead/behind counts | ✅ |
| `git show -s --format=%ct` | Commit timestamps | ✅ |
| `git status` | Working tree status inside mount | ✅ |
| `git diff` | Unified diffs for modified files | ✅ |
| `git add` / `git commit` / `git checkout` | Standard operations inside mount | ✅ |

All commands ArtifactFS depends on are fully implemented in ziggit.

## Quick start

### Prerequisites

- [ziggit](https://github.com/hdresearch/ziggit) installed and available as `git` in your PATH (or symlinked)
- [ArtifactFS](https://github.com/cloudflare/artifact-fs) (`go install github.com/cloudflare/artifact-fs/cmd/artifact-fs@latest`)
- FUSE: [macFUSE](https://osxfuse.github.io/) on macOS, `fuse3` on Linux

### Option 1: Symlink ziggit as git

```bash
# Make ziggit available as 'git' so ArtifactFS uses it
ln -sf $(which ziggit) /usr/local/bin/git

# Or add a directory with the symlink to the front of PATH
mkdir -p ~/bin
ln -sf $(which ziggit) ~/bin/git
export PATH=~/bin:$PATH
```

### Option 2: Use GIT_EXEC_PATH (if ArtifactFS respects it)

```bash
export PATH="$(dirname $(which ziggit)):$PATH"
```

### Mount a repo with ArtifactFS + ziggit

```bash
export ARTIFACT_FS_ROOT=/tmp/artifact-fs-data

# Register a repo (performs blobless clone via ziggit)
artifact-fs add-repo \
  --name my-project \
  --remote https://github.com/org/my-project.git \
  --branch main \
  --mount-root /tmp

# Start the FUSE daemon
artifact-fs daemon --root /tmp &
DAEMON_PID=$!

# The tree is visible immediately — file reads trigger on-demand hydration
ls /tmp/my-project/
cat /tmp/my-project/README.md

# Git operations work inside the mount
git -C /tmp/my-project log --oneline -10
git -C /tmp/my-project status

# Clean up
kill $DAEMON_PID
```

## How partial clone works

When ArtifactFS runs `git clone --filter=blob:none`, ziggit:

1. Connects to the remote via smart HTTP protocol (v1 or v2)
2. Sends `filter blob:none` in the capability/argument negotiation
3. The server responds with only commits, trees, and refs — no blob content
4. ziggit writes the pack file and configures the repo as a promisor remote:

```ini
[remote "origin"]
    url = https://github.com/org/repo.git
    fetch = +refs/heads/*:refs/remotes/origin/*
    promisor = true
    partialclonefilter = blob:none
```

When ArtifactFS later runs `git cat-file --batch` to hydrate a specific blob, git fetches just that blob from the promisor remote on demand.

## Docker / Container usage

ArtifactFS provides a Dockerfile for container environments. To use ziggit inside it, add ziggit to the build:

```dockerfile
FROM golang:1.24 AS builder
# ... build artifact-fs ...

FROM ubuntu:24.04
# Install ziggit via Homebrew or direct download
RUN apt-get update && apt-get install -y fuse3 curl
RUN curl -L https://github.com/hdresearch/ziggit/releases/latest/download/ziggit-linux-x86_64 -o /usr/local/bin/git && chmod +x /usr/local/bin/git

COPY --from=builder /go/bin/artifact-fs /usr/local/bin/
# ... rest of entrypoint ...
```

Run with FUSE access:
```bash
docker run --rm --cap-add SYS_ADMIN --device /dev/fuse my-artifact-fs-image
```

## Cloudflare Artifacts integration

If you're using [Cloudflare Artifacts](https://developers.cloudflare.com/artifacts/) as your remote, ziggit works the same way — Artifacts exposes standard Git smart HTTP endpoints:

```bash
# Clone from Artifacts with blobless filter
ziggit clone --filter=blob:none \
  https://x:${ARTIFACTS_TOKEN}@${ACCOUNT_ID}.artifacts.cloudflare.net/git/default/my-repo.git \
  /tmp/my-repo

# Or use ArtifactFS for automatic hydration
artifact-fs add-repo \
  --name my-repo \
  --remote "https://x:${ARTIFACTS_TOKEN}@${ACCOUNT_ID}.artifacts.cloudflare.net/git/default/my-repo.git" \
  --branch main \
  --mount-root /tmp
```

## Performance comparison

For a ~130K LOC repository (ziggit itself):

| Method | Pack size | Time |
|--------|-----------|------|
| Full clone (`ziggit clone --bare`) | 11 MB | ~3s |
| Blobless clone (`ziggit clone --filter=blob:none --bare`) | 1.1 MB | ~1s |

The blobless clone transfers 10x less data. File contents are then fetched individually on demand via `cat-file --batch`, which ArtifactFS manages transparently.

## Supported filter specs

ziggit supports the following `--filter` values:

| Filter | Description |
|--------|-------------|
| `blob:none` | Exclude all blobs (blobless clone — what ArtifactFS uses) |
| `blob:limit=<n>` | Exclude blobs larger than n bytes |
| `tree:<depth>` | Exclude trees beyond depth (0 = no trees) |
