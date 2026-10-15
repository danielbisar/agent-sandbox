# Agent Sandbox

Agent Sandbox builds local, non-root Docker images for exactly one of Codex, Claude, or Pi. All variants share Debian/Node tooling, `/home/agent/src` as their workspace, and `/home/agent/.agent-state` as persistent state.

## Security and privacy disclaimer

**This is a convenience environment, not a hardened sandbox for untrusted agents or agent-generated code.** Docker and Podman provide useful isolation, but ordinary Linux containers share the kernel of the machine running the container engine. Non-root execution reduces privileges; it does not eliminate container-escape risks. Docker Desktop runs its engine inside a VM, but that does not protect files and credentials explicitly shared with containers. See [Docker's security overview](https://docs.docker.com/engine/security/) and [bind-mount considerations](https://docs.docker.com/engine/storage/bind-mounts/#considerations-and-constraints).

In this project:

- Agents run with permission-bypass flags by default and can modify or delete files in the read-write workspace mount.
- Agents can access mounted source code and persistent state, including credentials, subject to filesystem permissions. `--read-only` prevents workspace writes, not reading or disclosing its contents; persistent state remains writable.
- `--safe` invokes the vendor CLI without the wrapper's permission-bypass flags. It does not add OS isolation or network restrictions, and vendor defaults are not a guarantee of safe behavior.

**Container isolation does not prevent data leakage over the network.** These wrappers use Docker's default bridge network, which [allows outbound connections](https://docs.docker.com/engine/network/). There is no project-managed egress filtering. An agent or a command it executes can transmit accessible code or credentials to reachable destinations; legitimate model API requests can also send source code to the provider. Read-only mounts do not prevent this.

**Telemetry and provider data handling remain vendor-controlled.** The images configure update-check or auto-update disabling, but the wrappers do not configure telemetry, analytics, or error-reporting opt-outs. Their behavior depends on the installed agent version, its configuration, and your account or organization policies. Neither `--safe` nor `--read-only` disables those features. Review and configure the vendor's privacy settings separately; running a CLI locally in a container does not mean its processing or data storage is local-only.

For potentially hostile workloads, prefer a separately isolated, hardened VM or microVM environment, such as [Firecracker](https://github.com/firecracker-microvm/firecracker/blob/main/docs/design.md), with a separate guest kernel and hardware-backed virtualization boundary. This is stronger workload isolation, not an absolute security guarantee. **MicroVMs do not inherently prevent network exfiltration either:** Firecracker explicitly requires host-level filtering of untrusted guest egress. Minimize shared files and credentials, enforce network policy outside the agent's control, and account for data sent to allowed model endpoints. This project does not provision microVMs or enforce those policies.

Use disposable workspaces and least-privilege credentials. Do not expose personal, employer, or customer data unless you are authorized to do so and the isolation, network controls, and provider data-handling terms meet your requirements.

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
