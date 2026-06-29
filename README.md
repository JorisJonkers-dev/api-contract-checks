# api-contract-checks

Reusable OpenAPI and generated TypeScript contract drift checks for
JorisJonkers-dev repositories.

## What It Is

`api-contract-checks` is a Bash CLI and composite GitHub Action that validates
that committed API contract artifacts still match fresh outputs from a service
build.

It can:

- export a fresh OpenAPI document into the committed spec path
- regenerate generated TypeScript contract files in place
- compare both outputs against source control
- run optional `oasdiff breaking` checks against a base spec

## CLI

Run one profile directly:

```bash
scripts/api-contract-checks.sh \
  --profile assistant-api \
  --spec-path services/assistant-api/openapi.json \
  --export-command './gradlew :services:assistant-api:exportOpenApiSpec' \
  --types-path services/assistant-ui/src/api/generated.ts \
  --types-generate-command 'pnpm --filter @personal-stack/assistant-ui contract:generate' \
  --breaking-check true \
  --breaking-base-ref origin/main \
  --guidance './gradlew :services:assistant-api:exportOpenApiSpec && pnpm --filter @personal-stack/assistant-ui contract:generate'
```

Run every profile in a directory, or one named subset:

```bash
scripts/api-contract-checks.sh --profiles-dir .github/contract-profiles
scripts/api-contract-checks.sh --profiles-dir .github/contract-profiles --only assistant-api
```

Profile files are trusted Bash fragments. Export and generation commands must
write their declared committed paths in place. Optional normalization commands
run after generation and receive `CONTRACT_PROFILE`, `CONTRACT_STAGE`,
`CONTRACT_SPEC_PATH`, and `CONTRACT_TYPES_PATHS` in the environment.

## Composite Action

Consumers pin the released action tag:

```yaml
- uses: JorisJonkers-dev/api-contract-checks@v0.1.0
  with:
    profile: assistant-api
    spec-path: services/assistant-api/openapi.json
    export-command: ./gradlew :services:assistant-api:exportOpenApiSpec
    types-paths: services/assistant-ui/src/api/generated.ts
    types-generate-command: pnpm --filter @personal-stack/assistant-ui contract:generate
    breaking-check: 'true'
    breaking-base-ref: origin/main
    guidance: ./gradlew :services:assistant-api:exportOpenApiSpec && pnpm --filter @personal-stack/assistant-ui contract:generate
```

## Local Use

```bash
tests/self-test.sh
```

`examples/basic` contains a minimal profile and generator pair. The self-test
covers clean runs, spec drift, generated TypeScript drift, and a deliberate
breaking-change failure.

## Links

- [Organization profile](https://github.com/JorisJonkers-dev)
- [Security policy](https://github.com/JorisJonkers-dev/.github/security/policy)
- [Changelog](./CHANGELOG.md)
- [License](./LICENSE)

Copyright (c) Joris Jonkers. Source available for viewing only; use, copying,
modification, redistribution, deployment, or reuse is not licensed. See
[LICENSE](./LICENSE).
