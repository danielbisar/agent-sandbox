# Repository Guidelines

This repository builds mutually exclusive Codex, Claude, and Pi Docker image variants from one multi-stage `Dockerfile`. Shared wrapper functions live in `lib.sh`; `build.sh`, `run.sh`, and `auth.sh` are Bash 3.2-compatible public interfaces. `test.sh` provides dependency-free fast checks and optional Docker integration checks.

Run `bash -n build.sh run.sh auth.sh lib.sh test.sh`, `./test.sh`, and ShellCheck after script changes. For container changes, run `./test.sh --integration --agent AGENT`. Authentication persistence is tested manually because it needs interactive credentials.

Keep the non-root `agent` identity, `/home/agent/src` workspace, and `/home/agent/.agent-state` contract consistent. Preserve label validation and exact version verification. Never create moving tags or automatically build from runtime scripts. Keep `.dockerignore` allowlist-based.

`state/` and legacy `home_codex/` are sensitive ignored data. Never copy, commit, migrate, or place them in the Docker context. Do not import content or history from `pi-sandbox`.

Keep commits focused and imperative. PRs should summarize wrapper or agent-specific behavior and list fast, integration, and manual validation performed. The GitHub rename and `pi-sandbox` pointer/archive are post-merge maintainer operations.
