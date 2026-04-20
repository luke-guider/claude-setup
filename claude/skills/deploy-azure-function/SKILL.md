---
name: deploy-azure-function
description: Use when deploying an Azure Function app from an unpublished feature branch in a Rush monorepo, when CI deploy fails because @guider-global packages aren't published yet. Symptoms - npm install fails with missing exports, TS2305 errors in CI, function deploy workflow fails on build step.
---

# Deploy Azure Function from Unpublished Branch

## Overview

Rush monorepo function deploys use `npm install` which pulls published packages from the registry. Feature branches with new exports in `@guider-global/*` packages will fail CI deploy until merged and version-bumped. This skill uses Verdaccio (local npm registry) to publish packages locally, then builds and deploys the function manually.

## When to Use

- CI function deploy fails with `TS2305 Module has no exported member` errors
- Feature branch adds new exports to shared packages (`models`, `shared-types`, etc.)
- Need to deploy functions to dev before merging to develop

## Steps

Execute these in order. Do not skip or reorder.

### 1. Start Verdaccio

```bash
# Install if needed
npm install -g verdaccio

# Ensure config allows unauthenticated publish
# ~/.config/verdaccio/config.yaml — all package scopes need publish: $all

# Clear any previous local packages
rm -rf ~/.config/verdaccio/storage/@guider-global

# Kill stale process, start fresh
lsof -ti:4873 | xargs kill -9 2>/dev/null
nohup verdaccio --listen 4873 > /tmp/verdaccio.log 2>&1 &
sleep 3
curl -s http://localhost:4873/ | wc -c  # Should be >0
```

### 2. Update publishConfig in all package.json files

```bash
for f in packages/*/package.json; do
  node -e "
    const fs = require('fs');
    const pkg = JSON.parse(fs.readFileSync('$f', 'utf8'));
    if (pkg.publishConfig && pkg.publishConfig['@guider-global:registry']) {
      pkg.publishConfig['@guider-global:registry'] = 'http://localhost:4873';
      fs.writeFileSync('$f', JSON.stringify(pkg, null, 2) + '\n');
    }
  "
done
```

### 3. Update all three npmrc files

**common/config/rush/.npmrc** and **root .npmrc**:
```
@guider-global:registry=http://localhost:4873
registry=http://localhost:4873
always-auth=false
auto-install-peers=true
```

**common/config/rush/.npmrc-publish**:
```
//localhost:4873/:_authToken=fake-token
@guider-global:registry=http://localhost:4873
registry=http://localhost:4873
always-auth=false
```

Back up originals first: `cp file file.bak`

### 4. Publish with Rush

```bash
rush build --only tag:packages   # Ensure all packages are built
rush publish -p --include-all    # Publish all shouldPublish=true packages
```

The `--include-all` flag publishes packages whose version doesn't exist in the local registry. The `-p` flag actually publishes (not dry run). The fake auth token in `.npmrc-publish` satisfies npm's auth requirement.

### 5. Install for the function app

```bash
cd functions/<function-name>

# Create local .npmrc to override user-level GitHub Packages config
cat > .npmrc << 'EOF'
//localhost:4873/:_authToken=fake-token
@guider-global:registry=http://localhost:4873
registry=http://localhost:4873
always-auth=false
EOF

rm -rf node_modules
npm install
```

### 6. Build the function

```bash
npx heft build --clean
```

### 7. Deploy

```bash
# Create flat deployment folder (no symlinks)
cd /path/to/monorepo
rush deploy --overwrite --scenario functions --project @guider-global/<project-name>

# Deploy to Azure
cd common/deploy/functions/<function-folder>
func azure functionapp publish <function-app-name> --javascript

# Restart to pick up new functions
az functionapp restart --name <function-app-name> --resource-group <resource-group>

# Verify all functions registered (may take 30-60s)
az functionapp function list --name <function-app-name> --resource-group <rg> --query "[].name" -o tsv
```

### 8. Clean up

```bash
# Restore npmrc files from backups
cp common/config/rush/.npmrc.bak common/config/rush/.npmrc
cp common/config/rush/.npmrc-publish.bak common/config/rush/.npmrc-publish
cp common/config/rush/.npmrc .npmrc

# Restore package.json publishConfig
for f in packages/*/package.json; do
  node -e "
    const fs = require('fs');
    const pkg = JSON.parse(fs.readFileSync('$f', 'utf8'));
    if (pkg.publishConfig && pkg.publishConfig['@guider-global:registry'] === 'http://localhost:4873') {
      pkg.publishConfig['@guider-global:registry'] = 'https://npm.pkg.github.com';
      fs.writeFileSync('$f', JSON.stringify(pkg, null, 2) + '\n');
    }
  "
done

# Remove function-local .npmrc
rm functions/<function-name>/.npmrc

# Stop verdaccio
lsof -ti:4873 | xargs kill 2>/dev/null
```

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| `npm publish --registry` ignored for scoped packages | The `@guider-global:registry` in `.npmrc` or `publishConfig` overrides `--registry`. Must update all three locations. |
| `ENEEDAUTH` from rush publish | Add `//localhost:4873/:_authToken=fake-token` to `.npmrc-publish`. Rush copies this to its temp home. |
| `rush publish` publishes nothing | Use `--include-all` — without it, rush only publishes packages with change files in `common/changes`. |
| User-level `~/.npmrc` overrides project | Create a `.npmrc` in the function directory itself — npm checks project > user > global. |
| Functions don't appear after deploy | Azure Functions runtime takes 30-60s to register new triggers. Restart and wait. |
| Verdaccio port in use | `lsof -ti:4873 | xargs kill -9` before starting. |

## Project-Specific Values

| Function | Project Name | App Name (dev) | Resource Group |
|----------|-------------|----------------|----------------|
| integrations | function-integrations | guider-integrations-dev | dev |
| webhooks | webhooks | guider-webhooks-dev | dev |
| timer-triggers | timer-triggers | timer-triggers-dev | dev |
| acs-event-grid | acs-event-grid | guider-acs-event-grid-dev | dev |
