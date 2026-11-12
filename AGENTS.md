# Agents

Guidance for any coding agent working in this repository.

The repository's agent contract is [CLAUDE.md](CLAUDE.md). The estate-wide conventions (labels, traps) are in the [estate contract](https://github.com/JorisJonkers-dev/workspace/blob/main/CLAUDE.md); read both before non-trivial changes.

This repository is a Bash CLI (`scripts/api-contract-checks.sh`) and composite GitHub Action (`action.yml`) that check OpenAPI and generated TypeScript contract drift. See `README.md` and `docs/REPO_SETUP.md`.

## Build and test

- `tests/self-test.sh` runs the self-test, as CI does.
- CI also runs shellcheck over `scripts/*.sh`, `tests/*.sh` and `examples/basic/scripts/*.sh`, and actionlint over the workflows.
- Do not hand-edit `CHANGELOG.md`; release-please owns it (see `CONTRIBUTING.md`).
