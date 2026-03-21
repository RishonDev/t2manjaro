# manjarot2.github.io
GitHub mirror for Manjaro T2 Kernels

## Kernel Repo Update Bot

This repo includes a controller workflow at `.github/workflows/kernel-release-bot.yml`.
It runs once a week, pulls the latest built `linux618-t2` release assets from the kernel build repo, rebuilds the pacman repo metadata, and replaces the kernel-related assets in the GitHub release that acts as the Manjaro repo.

The pacman repo endpoint stays the same because the workflow updates the existing release tag instead of creating a new repo URL.

## Targets

The default release sync settings are defined in `.github/release-sync-config.json`:

- source repo: `RishonDev/manjaro-kernel-t2`
- source assets: latest `linux618-t2` and `linux618-t2-headers` packages
- target repo: `RishonDev/t2manjaro`
- target release tag: `2601`

## Authentication

The workflow uses the built-in `GITHUB_TOKEN` to update release assets in this repository.
