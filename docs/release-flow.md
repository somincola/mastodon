# Release workflow for the custom fork

This repository keeps Mastodon’s upstream history while layering on your theme and configuration tweaks. The release workflow mirrors that: `main` tracks upstream, `custom-ui-fix` carries your patch set, and every published release gets its own `stable-*` branch plus a tagged commit that GitHub Actions can turn into Docker images.

## Branch responsibilities
- `main` should stay synchronized with `mastodon/main`. You can merge (or rebase) upstream changes as they land, but avoid committing custom edits directly on `main`.  
- `custom-ui-fix` (or another feature branch) is where you keep your UI, styling, and business logic changes. Rebase or merge it on top of `main` before publishing.  
- Version tags (e.g., `v4.5.2`) mark specific releases. Tag your `custom-ui-fix` branch when ready to build a new version.

## Release steps

1. **Sync upstream** (optional, to get latest updates):
   ```bash
   git fetch upstream
   git checkout main
   git merge upstream/main
   git push origin main
   ```

2. **Update your custom branch**:
   ```bash
   git checkout custom-ui-fix
   git merge main  # or rebase if you prefer
   git push origin custom-ui-fix
   ```

3. **Create a version tag**:
   ```bash
   # Make sure you're on the commit you want to tag
   git checkout custom-ui-fix
   
   # Create and push the tag (format: vX.Y.Z)
   git tag v4.5.2
   git push origin v4.5.2
   ```

4. **GitHub Actions will automatically**:
   - Detect the tag push
   - Build Docker images for both `bailongctui/mastodon` and `bailongctui/mastodon-streaming`
   - Tag them with version number (e.g., `4.5.2`, `4.5`) and `latest` (if tag matches `v4.5.*`)

5. **Deploy to your server**:
   ```bash
   docker pull bailongctui/mastodon:4.5.2
   # Or use :latest for automatic updates
   docker pull bailongctui/mastodon:latest
   ```

## Conflict handling
- Conflicts with upstream should be resolved when merging `upstream/main` into `main`.  
- Conflicts between upstream and your custom changes show up when merging `main` into `custom-ui-fix`; resolve them there before running the release script.  
- The script will stop if a merge conflict occurs—resolve it manually, commit, and rerun.

## Mirror tags and images
- Keep tagging with a `v4.5.*` prefix so `.github/workflows/build-image.yml` will push `latest`.  
- `build-image.yml` pushes two tags per run: `type=pep440,pattern={{raw}}` and `type=pep440,pattern=v{{major}}.{{minor}}`. `{{raw}}` becomes your tape `v4.5.2-2025.11.21`.
- `latest` maps to the last release tag that still matches `v4.5.*`, so deploying `:latest` equals “the newest tagged release that matched the pattern.”

