# Agent Sandbox

Agent Sandbox builds local, non-root container images with Docker or Podman for exactly one of Codex, Claude, or Pi. All variants share Debian/Node tooling, `/home/agent/src` as their workspace, and `/home/agent/.agent-state` as persistent state.

## Security and privacy disclaimer

**This is a convenience environment, not a hardened sandbox for untrusted agents or agent-generated code.** Docker and Podman provide useful isolation, but ordinary Linux containers share the kernel of the machine running the container engine. Non-root execution reduces privileges; it does not eliminate container-escape risks. Docker Desktop runs its engine inside a VM, but that does not protect files and credentials explicitly shared with containers. See [Docker's security overview](https://docs.docker.com/engine/security/) and [bind-mount considerations](https://docs.docker.com/engine/storage/bind-mounts/#considerations-and-constraints).

In this project:

- Agents run with permission-bypass flags by default and can modify or delete files in the read-write workspace mount.
- Agents can access mounted source code and persistent state, including credentials, subject to filesystem permissions. `--read-only` prevents workspace writes, not reading or disclosing its contents; persistent state remains writable.
- `--safe` invokes the vendor CLI without the wrapper's permission-bypass flags. It does not add OS isolation or network restrictions, and vendor defaults are not a guarantee of safe behavior.

**Container isolation does not prevent data leakage over the network.** These wrappers use the selected engine's default networking, normally allowing outbound connections; see [Docker networking](https://docs.docker.com/engine/network/) and [Podman networking](https://docs.podman.io/en/latest/markdown/podman-run.1.html#network-mode-net). There is no project-managed egress filtering. An agent or a command it executes can transmit accessible code or credentials to reachable destinations; legitimate model API requests can also send source code to the provider. Read-only mounts do not prevent this.

**Telemetry and provider data handling remain vendor-controlled.** The images configure update-check or auto-update disabling, but the wrappers do not configure telemetry, analytics, or error-reporting opt-outs. Their behavior depends on the installed agent version, its configuration, and your account or organization policies. Neither `--safe` nor `--read-only` disables those features. Review and configure the vendor's privacy settings separately; running a CLI locally in a container does not mean its processing or data storage is local-only.

For potentially hostile workloads, prefer a separately isolated, hardened VM or microVM environment, such as [Firecracker](https://github.com/firecracker-microvm/firecracker/blob/main/docs/design.md), with a separate guest kernel and hardware-backed virtualization boundary. This is stronger workload isolation, not an absolute security guarantee. **MicroVMs do not inherently prevent network exfiltration either:** Firecracker explicitly requires host-level filtering of untrusted guest egress. Minimize shared files and credentials, enforce network policy outside the agent's control, and account for data sent to allowed model endpoints. This project does not provision microVMs or enforce those policies.

Use disposable workspaces and least-privilege credentials. Do not expose personal, employer, or customer data unless you are authorized to do so and the isolation, network controls, and provider data-handling terms meet your requirements.

## Build

Docker or Podman, and Bash 3.2 or newer, are required. The wrappers prefer Docker when both commands are installed, otherwise use Podman. Set `CONTAINER_ENGINE=docker` or `CONTAINER_ENGINE=podman` to choose explicitly; a selected engine's failure is reported rather than silently switching engines. Images must be built and launched using the same engine's image store.

The default base image is `docker.io/library/node:24-slim`, explicitly qualified to avoid Podman short-name registry prompts. Rootless Podman launches map the host user to the image's labeled agent UID/GID using `--userns=keep-id:uid=...,gid=...` and explicitly run as `agent`. This preserves access to host-owned workspaces and private state without changing their ownership. Your Podman installation must support these options and have working subordinate UID/GID mappings. For rootful Docker or Podman on Linux, use `--uid`/`--gid` at build time to match host ownership where needed. Rootless Docker's UID/GID mapping is not configured by these wrappers.

```bash
./build.sh --agent codex
./build.sh --agent claude --version 1.2.3 --no-pull
./build.sh --agent pi --base-image docker.io/library/node:24-slim --uid 1000 --gid 1000 \
  --tools "make,gcc" --tools "make,zip=3.0-13" --suffix dev
```

Omitting `--version` installs the newest stable release. Images are tagged only as `agent-sandbox:<agent>-<version>`, with `-<suffix>` when supplied; no `latest` tag is created. Extra tools must be valid Debian package names, optionally version-pinned. The image records build, source, identity, base-image, package, agent, version, and suffix labels and verifies the installed CLI before tagging.

Explicit versions must be valid SemVer, including optional prerelease identifiers and build metadata. Docker tags encode the metadata separator `+` as `_` (for example, `1.2.3+build.1` becomes `1.2.3_build.1`); image labels and `--version` selection retain the original version. Prereleases require an explicit version request. Final-image verification compares the complete parsed version, including prerelease and metadata, before assigning the versioned tag.

### Custom CA certificates

For a company HTTPS proxy or private CA, pass one PEM-encoded public CA certificate per file. Repeat `--ca-cert` for additional CAs; paths are relative to your current directory. This option requires OpenSSL on the host.

```bash
./build.sh --agent codex --ca-cert ~/certificates/company-root.crt --suffix company
./auth.sh --agent codex --suffix company
./run.sh --agent codex --suffix company /path/to/project
```

The build validates each certificate, rejects private keys and certificate bundles, and copies only the selected certificates and Dockerfile into a temporary allowlisted context. Certificates are installed into the image's system trust store before agent installation. `NODE_EXTRA_CA_CERTS` also extends Node's trust using the system bundle. No certificate argument is needed at runtime. Rebuild with replacement certificates when trust changes; certificate contents participate in build caching. Without `--ca-cert`, no additional CA trust is configured.

Only supply CAs you are authorized to trust: a trusted interception CA can authorize certificates for intercepted HTTPS connections. Certificates remain in the image and build cache and may disclose organizational information; do not distribute customized images without permission. Never supply a private key. This does not support mutual-TLS client authentication, disable TLS verification, or guarantee that every vendor binary or extension uses the configured trust stores.

This option configures **image trust, not engine/host trust**. If pulling the base image fails TLS validation, configure Docker/Podman trust separately. Installing the system CA tooling also requires working apt access in the base image; custom bases using HTTPS-only repositories may need CA trust bootstrapped in advance.

## Authenticate and run

```bash
./auth.sh --agent codex
./run.sh --agent codex /path/to/workspace
./run.sh --agent claude --safe --read-only . -- --model sonnet
./run.sh --agent pi --shell . -- -lc 'git status'
```

Both commands select the highest stable, unsuffixed local image unless `--version` or `--suffix` narrows selection. They validate image labels and print the exact build command when none matches. Relative paths are resolved from the caller's directory. Containers are interactive, disposable, and use the selected engine's default networking.

State defaults to `state/<agent>` or can be selected directly with `--state-dir PATH`. Missing directories are created mode 0700. Authentication is not required before normal launch. Codex authentication uses device login; Claude and Pi start their interactive provider setup. State can be shared by concurrent containers, so applications—not these wrappers—coordinate writes. Treat state as secret and never commit it.

`run.sh` mounts workspaces read-write unless `--read-only` is used. Agents run unrestricted unless `--safe` restores vendor defaults. `--shell` starts Bash. Arguments after `--` are passed unchanged. `--selinux` adds private `:Z` relabeling to managed mounts.

Repeat `--skills PATH` or `--skills-rw PATH` to mount skill directories beneath `.agent-state/skills`. Name collisions use `-2`, `-3`, and so on. Pi alone supports one complete extensions directory via `--extensions PATH` (read-only) or `--extensions-rw PATH`.

## Tests

```bash
./test.sh
./test.sh --integration
./test.sh --integration --agent codex
./test-ca.sh --integration
```

Fast tests require no additional dependencies; CA validation/context tests run when OpenSSL is available. The optional CA integration test requires OpenSSL, Python 3, and a local Linux container engine with host networking. It creates disposable certificates and a loopback HTTPS server, verifies system and Node trust as `agent`, and checks that replacing the CA invalidates cached trust. It does not use real authentication state. Agent integration builds and smoke-tests images. Authentication persistence is manual: authenticate, exit, rerun authentication with the same state directory, and confirm credentials remain available.

## License and third-party software

The original wrappers, Dockerfile, and documentation in this repository are licensed under the [MIT License](LICENSE). The coding agents, base image, and installed tools are third-party software; this repository's license does not relicense them.

- [Codex](https://github.com/openai/codex) is licensed under Apache-2.0.
- [Pi](https://github.com/earendil-works/pi) is licensed under MIT.
- [Claude Code](https://code.claude.com/docs/en/legal-and-compliance) is governed by Anthropic's applicable terms, not this repository's MIT license.
- Node.js, Debian packages, and their dependencies retain their respective licenses and notices.

The scripts build images locally and do not publish them. Before redistributing an image, review the licenses, notices, and vendor terms for the exact versions and dependencies it contains.

Agent Sandbox is an independent project, not affiliated with or endorsed by OpenAI, Anthropic, or the Pi maintainers. The contribution here is the container setup and wrapper tooling, not the underlying agents.
