# Release workflow for the custom fork

This repository keeps Mastodon’s upstream history while layering on your theme and configuration tweaks. The release workflow mirrors that: `main` tracks upstream, `custom-ui-fix` carries your patch set, and every published release gets its own `stable-*` branch plus a tagged commit that GitHub Actions can turn into Docker images.

## Branch responsibilities
- `main` should stay synchronized with `mastodon/main`. You can merge (or rebase) upstream changes as they land, but avoid committing custom edits directly on `main`.  
- `custom-ui-fix` (or another feature branch) is where you keep your UI, styling, and business logic changes. Rebase or merge it on top of `main` before publishing.  
- `stable-<version>` branches are short-lived snapshots created for each release. They point to the commit you tagged (combined `main` + `custom-ui-fix`) and are what your Docker build workflow consumes.

## Release steps
1. Run `git fetch upstream` and merge `upstream/main` into `main`. Resolve any upstream conflicts on `main` so it still mirrors the official repository.  
2. Rebase or merge `main` into `custom-ui-fix` to bring your changes up to date. Resolve conflicts here if they touch the same files.  
3. Use `scripts/release-flow.sh` (see next section) to:
   - create a new `stable-<version>` branch based on `custom-ui-fix`,
   - tag it with `v<version>-<suffix>`, and
   - push the branch and tag to `origin`.
4. GitHub Actions (`.github/workflows/build-image.yml`) will notice the tag and build both `bailongctui/mastodon:<tag>` and `bailongctui/mastodon:latest`. The streaming image is built from the same source tree, so it stays in sync.
5. On your server, pull the new image (`:latest` or the explicit `:<tag>`) and restart the services.

## Using `scripts/release-flow.sh`
The script encodes the release steps above; it:

1. Ensures there are no uncommitted changes.  
2. Fetches `upstream`, merges it into `main`, and pushes `main` to `origin`.  
3. Merges `main` into your custom branch (`custom-ui-fix` by default) and creates `stable-<version>`.  
4. Tags the new commit as `v<version>-<suffix>` (default suffix is today’s date).  
5. Pushes the stable branch and tag so the build workflow can fire.

Example:
```bash
chmod +x scripts/release-flow.sh
./scripts/release-flow.sh 4.5.2 2025.11.21
```

You can customize the script with environment variables:
- `CUSTOM_BRANCH` overrides `custom-ui-fix`.  
- `STABLE_PREFIX` / `TAG_PREFIX` adjust the naming strategy.  
- `UPSTREAM_REMOTE` defaults to `upstream`.

Run the script from any branch; it will check out `main`, `custom-ui-fix`, and the new stable branch as needed and leave you on the tagged commit.

## Conflict handling
- Conflicts with upstream should be resolved when merging `upstream/main` into `main`.  
- Conflicts between upstream and your custom changes show up when merging `main` into `custom-ui-fix`; resolve them there before running the release script.  
- The script will stop if a merge conflict occurs—resolve it manually, commit, and rerun.

## Mirror tags and images
- Keep tagging with a `v4.5.*` prefix so `.github/workflows/build-image.yml` will push `latest`.  
- `build-image.yml` pushes two tags per run: `type=pep440,pattern={{raw}}` and `type=pep440,pattern=v{{major}}.{{minor}}`. `{{raw}}` becomes your tape `v4.5.2-2025.11.21`.
- `latest` maps to the last release tag that still matches `v4.5.*`, so deploying `:latest` equals “the newest tagged release that matched the pattern.”

