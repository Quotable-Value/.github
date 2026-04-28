# NodeJS Checks Pilot

This reusable workflow is the first DEV-8027 pilot for QV NodeJS projects.

It is based on the current `validation` QA workflow:

- install dependencies with `npm install`
- run linting with `npm run lint`
- keep the coverage job commented out for the initial pilot

The consuming repository keeps ownership of its local config, including `.nycrc.yml`, ESLint config, npm scripts, and package lock files. The shared workflow only standardises the GitHub Actions wiring.

## Validation pilot caller

Use this in `validation/.github/workflows/qa.yml` while testing the shared workflow branch:

```yaml
name: QA

on:
  pull_request:
    branches:
      - feature/*
      - release/*
      - bugfix/*

jobs:
  nodejs:
    uses: Quotable-Value/.github/.github/workflows/nodejs-checks.yml@feature/DEV-8027-nodejs-actions-pilot
    with:
      runner: codebuild-quotable-value-validation-build-${{ github.run_id }}-${{ github.run_attempt }}
      node-version: '20'
    secrets: inherit
```

## Monorepo caller shape

For `monarch-apis`, pass the service directory as `working-directory`:

```yaml
jobs:
  consent:
    uses: Quotable-Value/.github/.github/workflows/nodejs-checks.yml@feature/DEV-8027-nodejs-actions-pilot
    with:
      working-directory: consent
      node-version: '20'
    secrets: inherit
```

Path filtering should stay in the caller workflow so the shared workflow remains reusable across single-repo and monorepo projects.
