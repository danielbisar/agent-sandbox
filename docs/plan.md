# Merge Codex, Claude, and Pi into Agent Sandbox

## Summary

Transform `codex-docker` into `agent-sandbox`, a Docker project that builds mutually exclusive Codex, Claude, or Pi image variants. Preserve the existing MIT license and Git history, but do not import `pi-sandbox` history, credentials, sessions, or caches.

Implementation will be delivered through a feature branch and PR. The GitHub repository rename and `pi-sandbox` archival remain manual post-merge steps.

## Image Architecture

- Use one multi-stage Dockerfile with a shared Debian/Node base and named `codex`, `claude`, and `pi` targets.
- Create a common non-root `agent` user, configurable at build time and defaulting to UID/GID `1000:1000`.
- Use `/home/agent/src` as the workspace and `/home/agent/.agent-state` as the standardized persistent state location.
- Install common packages: CA certificates, curl, Git, ripgrep, `fd-find`, and jq. Do not add an `fd` alias.
- Retain the existing Git rebase, autostash, and fast-forward settings with the identity `Agent Sandbox <agent@no-mail.com>`.
- Install exactly one agent:
  - Codex: official `@openai/codex` npm package.
  - Claude: supported native installer.
  - Pi: latest `@earendil-works/pi-coding-agent`.
- Run npm lifecycle scripts normally.
- Disable automatic agent updates while leaving telemetry at vendor defaults.
- Default each image to its agent's unrestricted mode.

## Build Interface

```bash
./build.sh --agent codex|claude|pi [OPTIONS]
```

Supported options:

- `--version VERSION`: exact semantic version, including prereleases. Omission resolves the newest stable release.
- `--base-image IMAGE`: defaults to `node:24-slim`; alternatives must provide Debian, Bash, Node.js, npm, and apt.
- `--no-pull`: skip the default base-image pull.
- `--uid UID` and `--gid GID`: default to `1000`.
- Repeatable `--tools "pkg1,pkg2,..."`: add validated Debian packages, including optional `=version` pins; combine lists and remove exact duplicates.
- `--suffix VALUE`: append a custom tag suffix without wrapper validation; Docker reports invalid tag syntax.

Build only versioned local tags:

```text
agent-sandbox:<agent>-<version>
agent-sandbox:<agent>-<version>-<suffix>
```

Do not create moving `latest` tags. Rebuilding replaces an existing matching local tag normally.

Record image labels for:

- Agent, installed version, and optional suffix.
- Base image, UID/GID, and normalized extra-package list.
- Git commit and dirty-state flag.
- UTC build timestamp.

Verify the installed CLI reports the expected version before assigning the final tag.

## Runtime and Authentication Interfaces

```bash
./run.sh --agent codex|claude|pi [OPTIONS] WORKSPACE [-- AGENT_ARGS...]
./auth.sh --agent codex|claude|pi [OPTIONS] [-- AUTH_ARGS...]
```

Both scripts:

- Discover the highest stable local version by default.
- Support explicit `--version` and `--suffix`.
- Consider unsuffixed images unless `--suffix` is supplied.
- Validate image agent, version, and suffix labels before launch.
- Fail with an exact suggested build command when no image matches; never build automatically.
- Resolve user-supplied relative paths from the caller's working directory.
- Run interactive disposable containers with `-it --rm`.

`run.sh` behavior:

- Accept any existing workspace directory and mount it at `/home/agent/src`.
- Mount workspaces read-write by default; `--read-only` changes only the workspace mount.
- Start agents unrestricted by default; `--safe` restores vendor permission behavior.
- `--shell` launches Bash and forwards arguments after `--` to Bash.
- Otherwise, forward arguments after `--` unchanged to the selected agent.
- Use Docker's standard bridge network and provide `--selinux` to apply private `:Z` relabeling to managed mounts.
- Do not add environment-variable forwarding, lifecycle, registry, Compose, or devcontainer abstractions.

`auth.sh` behavior:

- Codex: run device authentication.
- Claude and Pi: launch their normal interactive login/provider setup.
- Forward arguments after `--` to the selected setup command.

## Persistent State and Extensions

- Default host state to ignored `state/<agent>`.
- Treat `--state-dir PATH` as the selected agent's state directory directly.
- Create missing state directories with mode `0700`; do not require authentication before normal launch.
- Mount state at `/home/agent/.agent-state` and configure:
  - `CODEX_HOME` for Codex.
  - `CLAUDE_CONFIG_DIR` for Claude.
  - `PI_CODING_AGENT_DIR` for Pi.
- Permit concurrent containers to share state without wrapper-level locking.

Skills:

- Repeatable `--skills PATH` mounts a skill read-only.
- Repeatable `--skills-rw PATH` mounts a skill read-write.
- Mount skills beneath `.agent-state/skills` using their basenames.
- Resolve duplicate supplied names and conflicts with existing state skills using `name-2`, `name-3`, and subsequent suffixes.

Pi extensions:

- Support one complete directory through `--extensions PATH` or `--extensions-rw PATH`.
- Mount read-only by default and reject extension options for Codex or Claude.

## Repository Safety and Documentation

- Add an allowlist-style `.dockerignore` containing only required Docker build inputs, preventing credentials and repository contents from entering the build context.
- Ignore `state/` while retaining the legacy `home_codex/` ignore rule.
- Never copy or migrate current `home_codex/` or `pi-sandbox/pi/` contents.
- Rewrite README and AGENTS guidance for the three variants, complete CLI syntax, image discovery, state security, agent-specific behavior, and manual GitHub rename/archive steps.
- Document `pi-sandbox` archival pointer text without modifying that repository.
- Do not provide legacy command shims or a migration workflow.

## Test Plan

Add a dependency-free, Bash 3.2-compatible `test.sh`:

- Default tests use fake Docker and installer commands to validate parsing, errors, command construction, path handling, image discovery, semantic-version ordering, label validation, mount modes, and agent-specific option rejection.
- `test.sh --integration` builds and smoke-tests all three variants.
- `test.sh --integration --agent AGENT` limits integration testing to one variant.
- Integration checks verify the selected CLI and version, absence of the other agent CLIs, non-root identity, common tools, Git configuration, metadata labels, default command, standardized state environment, and shell launch.
- Authentication persistence remains a documented manual test because it requires interactive credentials.

Add GitHub Actions checks on Linux and macOS that run:

- Bash syntax checks.
- The fast test harness.
- ShellCheck.

Do not build Docker images or use credentials in CI.

## Assumptions

- Docker and Bash 3.2+ are the only required host tools.
- Images remain local and are not pushed by project scripts.
- The user will manually rename the GitHub repository after merging the PR.
- The user will manually add the pointer and archive `pi-sandbox`.
