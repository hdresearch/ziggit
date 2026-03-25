The goal is to make a modern version control software like git or jj but written in zig

ALL SYSTEMS AND AGENTS MUST use this github -> https://github.com/hdresearch/ziggit.git

For each of the below goals, create a VM and run code like the following

```bash
while true do
  pi -run "GOAL"
end
```

NOTE - pi is running on the VM itself rather than running on the host machine and then ssh'ing commands. This should be done so I can quit this pi session

So agents are just infinitely running since there is always something to improve in a piece of software. Include pi-vers extension so each infinite loop can provision further VMs or agents.

- first person like jj but does not have a `jj git` subcommand and instead is drop in replaceable with `git` so `ziggit checkout` not `ziggit git checkout`
- feature compatibility with git (copy over test suite from git source)
- can compile to webassembly
- can yield performance improvements to oven-sh/bun codebase by using directly with zig integration instead of libgit2 or git cli

Maybe wait for some progress before starting on replacing bun's usage of the git cli (which they use over libgit2 for performance reasons, my suspicion is that a modern solution in zig could be better). Every VM should have the env vars `VERS_API_KEY`, `ANTHROPIC_API_KEY`, `GITHUB_API_KEY`. Also use the hdresearch/bun fork with changes so a real PR can be created pointing at oven-sh/bun BUT DO NOT MAKE THIS PR YOURSELF. Provide instructions for a person to validate the benchmark results with ziggit usage first
