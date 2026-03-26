# Ziggit Agent Scripts

This directory contains the prompts and scripts used by autonomous AI agents (running [pi](https://github.com/mariozechner/pi-coding-agent) on [Vers](https://vers.dev) VMs) that collaboratively built ziggit.

## Active Agents

| Agent | Script | VM | Role |
|-------|--------|-----|------|
| **BUNCOMPAT** | `buncompat.sh` | `36cf902f` | Pure Zig package API for bun integration — `@import("ziggit")` with zero git dependency |
| **PERF-BENCH** | `perf-bench.sh` | `39b4d3fb` | Performance benchmarking: Zig API vs git CLI, optimization |
| **GIT-FALLBACK** | `git-fallback.sh` | `3c7cd4a2` | Git CLI fallback for unimplemented commands + native reimplementation |
| **CORE** | `core.sh` | `edc60f19` | Build system, integration tests, platform fixes |
| **IMPL** | `impl.sh` | `8af9bd4c` | Git format internals: pack files, config parser, index, refs |
| **LIBSTATUS** | `libstatus.sh` | `c0e95676` | Library C API: status porcelain, stubs |

## How It Works

Each agent runs in an infinite loop on a Vers VM:
1. Pull latest from `origin/master`
2. Run `pi -p "<prompt>"` with the agent's specific task
3. Auto-commit and push any changes
4. Sleep 10 seconds, repeat

Agents are isolated by file ownership:
- **BUNCOMPAT** owns `src/ziggit.zig` (Zig package API)
- **GIT-FALLBACK** owns `src/main_common.zig` (CLI + fallback)
- **IMPL** owns `src/git/*.zig` (git format internals)
- **LIBSTATUS** owns `src/lib/*.zig` (C library API)
- **CORE** owns `build.zig`, `src/platform/*`, `test/`
- **PERF-BENCH** owns `benchmarks/`

Merge conflicts are resolved via `git pull --rebase` with automatic abort+reset on failure.

## VM Setup

`vm-setup.sh` provisions a fresh Vers VM with:
- Node.js + pi coding agent
- Zig 0.13.0
- Git
- 2GB swap (VMs have 483MB RAM)
- The ziggit repo cloned and ready

## Reproducing

```bash
# Create a VM
vers branch --alias my-agent --wait
VM_ID=<id from output>
vers resize $VM_ID --size 8192

# Provision it
vers copy $VM_ID agents/vm-setup.sh /root/full-setup.sh
vers execute -t 600 $VM_ID -- bash -c "chmod +x /root/full-setup.sh && /root/full-setup.sh"

# Deploy an agent
vers copy $VM_ID agents/buncompat.sh /root/agent-run.sh
vers execute $VM_ID -- bash -c "chmod +x /root/agent-run.sh && systemctl start ziggit-agent"
```
