# Agent Sandbox

Agent Sandbox builds local, non-root Docker images for exactly one of Codex, Claude, or Pi. All variants share Debian/Node tooling, `/home/agent/src` as their workspace, and `/home/agent/.agent-state` as persistent state.

## Build

Docker and Bash 3.2 or newer are required.

```bash
./build.sh --agent codex
./build.sh --agent claude --version 1.2.3 --no-pull
./build.sh --agent pi --base-image node:24-slim --uid 1000 --gid 1000 \
  --tools "make,gcc" --tools "make,zip=3.0-13" --suffix dev
```

Omitting `--version` installs the newest stable release. Images are tagged only as `agent-sandbox:<agent>-<version>`, with `-<suffix>` when supplied; no `latest` tag is created. Extra tools must be valid Debian package names, optionally version-pinned. The image records build, source, identity, base-image, package, agent, version, and suffix labels and verifies the installed CLI before tagging.

## Authenticate and run

```bash
./auth.sh --agent codex
./run.sh --agent codex /path/to/workspace
./run.sh --agent claude --safe --read-only . -- --model sonnet
./run.sh --agent pi --shell . -- -lc 'git status'
```

Both commands select the highest stable, unsuffixed local image unless `--version` or `--suffix` narrows selection. They validate image labels and print the exact build command when none matches. Relative paths are resolved from the caller's directory. Containers are interactive, disposable, and use Docker's normal bridge network.

State defaults to `state/<agent>` or can be selected directly with `--state-dir PATH`. Missing directories are created mode 0700. Authentication is not required before normal launch. Codex authentication uses device login; Claude and Pi start their interactive provider setup. State can be shared by concurrent containers, so applications—not these wrappers—coordinate writes. Treat state as secret and never commit it.

`run.sh` mounts workspaces read-write unless `--read-only` is used. Agents run unrestricted unless `--safe` restores vendor defaults. `--shell` starts Bash. Arguments after `--` are passed unchanged. `--selinux` adds private `:Z` relabeling to managed mounts.

Repeat `--skills PATH` or `--skills-rw PATH` to mount skill directories beneath `.agent-state/skills`. Name collisions use `-2`, `-3`, and so on. Pi alone supports one complete extensions directory via `--extensions PATH` (read-only) or `--extensions-rw PATH`.

## Tests

```bash
./test.sh
./test.sh --integration
./test.sh --integration --agent codex
```

Fast tests require no dependencies. Integration builds and smoke-tests images. Authentication persistence is manual: authenticate, exit, rerun authentication with the same state directory, and confirm credentials remain available.
