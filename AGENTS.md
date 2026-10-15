# Repository Guidelines

## Project Structure & Architecture

This repository builds mutually exclusive Codex, Claude, and Pi Docker image variants from one multi-stage `Dockerfile`. Keep shared shell logic in `lib.sh`; `build.sh`, `run.sh`, and `auth.sh` are the Bash 3.2-compatible public interfaces. `test.sh` contains dependency-free checks plus optional Docker integration tests. User documentation belongs in `README.md`, with longer design notes under `docs/`.

Preserve the runtime contract: containers use the non-root `agent` identity, `/home/agent/src` as the workspace, and `/home/agent/.agent-state` for persistent state. Do not create moving image tags or trigger builds from runtime scripts. Retain label validation, exact installed-version verification, and the allowlist-based `.dockerignore`.

## Build, Test, and Development Commands

- `./build.sh --agent codex` builds one agent-specific image; substitute `claude` or `pi`.
- `./run.sh --agent codex .` launches a built image with the current workspace.
- `./auth.sh --agent codex` initializes credentials in persistent state.
- `bash -n build.sh run.sh auth.sh lib.sh test.sh` checks shell syntax.
- `./test.sh` runs fast checks without Docker.
- `./test.sh --integration --agent codex` builds and smoke-tests one variant; omit `--agent` to test all variants.
- `shellcheck build.sh run.sh auth.sh lib.sh test.sh` performs static analysis.
- `shfmt -i 2 -ci -sr -w build.sh run.sh auth.sh lib.sh test.sh` formats all shell scripts; replace `-w` with `-d` to check formatting without modifying files.

## Coding Style & Naming Conventions

Write portable Bash compatible with macOS Bash 3.2. Match the existing two-space indentation, lowercase `snake_case` variables and functions, quoted expansions, and `set -e`/`set -u` discipline. Prefer shared helpers in `lib.sh` over duplicating validation or image-selection logic. Keep CLI options descriptive and kebab-cased, such as `--base-image` and `--state-dir`.

Keep shell scripts readable rather than compressed. Leave a blank line after shell options such as `set -euo pipefail`. Put each variable assignment and statement on its own line; do not group assignments or separate commands with semicolons. Expand function bodies, case branches, and control-flow bodies onto separate lines, with `shift`, `esac`, `done`, and `fi` on their own lines. Headers such as `while ...; do` and `if ...; then` are fine, but their bodies must start on the next line. Compact command substitutions such as `script_dir=$(cd ... && pwd)` are also fine.

Use blank lines to separate logical phases and split long commands or pipelines across lines where it improves readability. Add brief comments for non-obvious behavior or compatibility constraints, not for self-explanatory statements. Use `shfmt` with the options above, then manually check grouped assignments and shell code embedded in strings or heredocs, which formatting alone may not expand.

## Testing Guidelines

Add focused assertions to `test.sh` for every behavior change, including invalid inputs and agent-specific restrictions. Run syntax checks, fast tests, and ShellCheck after script edits. For Dockerfile or container behavior, also run the relevant integration test. Authentication persistence requires manual verification with interactive credentials; record that result in the PR.

## Security & Sensitive State

`state/` and legacy `home_codex/` contain ignored secrets. Never copy, commit, migrate, or include them in the Docker context. Do not import files or history from `pi-sandbox`.

## Commits & Pull Requests

Use focused, imperative commit subjects, for example `Add Pi integration checks`. PRs should summarize wrapper and agent-specific behavior, note compatibility implications, and list fast, integration, and manual validation performed. Repository renaming and the `pi-sandbox` pointer/archive remain post-merge maintainer operations.
