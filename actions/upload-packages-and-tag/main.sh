#!/bin/bash

# Copyright (c) Meta Platforms, Inc. and affiliates.
# All rights reserved.
#
# This source code is licensed under the terms described in the LICENSE file in
# the root directory of this source tree.

if [ -z "$VERSION" ]; then
  echo "You must set the VERSION environment variable" >&2
  exit 1
fi

if [ -z "$NPM_TOKEN" ]; then
  echo "You must set the NPM_TOKEN environment variable" >&2
  exit 1
fi

GITHUB_TOKEN=${GITHUB_TOKEN:-}
LLAMA_STACK_ONLY=${LLAMA_STACK_ONLY:-false}

source $(dirname "$0")/../common.sh

set -euo pipefail
set -x

npm config set '//registry.npmjs.org/:_authToken' "$NPM_TOKEN"

is_truthy() {
  case "$1" in
    true|1) return 0 ;;
    false|0) return 1 ;;
    *) return 1 ;;
  esac
}

run_precommit_lockfile_update() {
  # Use pre-commit to update lockfiles (uv.lock and package-lock.json)
  # For RC builds, LLAMA_STACK_RELEASE_MODE=true with UV config pointing to test.pypi
  # Note: pre-commit exits with non-zero when it modifies files, which is expected
  if ! command -v pre-commit &> /dev/null; then
    echo "ERROR: pre-commit is not installed" >&2
    exit 1
  fi
  echo "Running pre-commit to update lockfiles..."
  # Exclude third-party packages without wheels on test.pypi (psycopg2-binary)
  UV_EXTRA_INDEX_URL="https://test.pypi.org/simple/" \
    UV_INDEX_STRATEGY="unsafe-best-match" \
    UV_NO_BUILD_ISOLATION_PACKAGE="psycopg2-binary" \
    LLAMA_STACK_RELEASE_MODE=true \
    pre-commit run --all-files || true
  echo "pre-commit run completed."
}

# Parse version to derive release branch name
parse_version_and_branch() {
  local version=$1

  # Validate version format
  if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?(rc[0-9]+)?$ ]]; then
    echo "ERROR: Invalid version format: $version" >&2
    exit 1
  fi

  # Remove rc suffix if present
  local base_version=$(echo "$version" | sed 's/rc[0-9]*$//')

  # Extract major.minor
  local major=$(echo "$base_version" | cut -d. -f1)
  local minor=$(echo "$base_version" | cut -d. -f2)

  # Derive branch name
  echo "release-${major}.${minor}.x"
}

RELEASE_BRANCH=$(parse_version_and_branch "$VERSION")
echo "Derived release branch: $RELEASE_BRANCH"

TMPDIR=$(mktemp -d)
cd $TMPDIR

uv venv -p python3.12
source .venv/bin/activate

uv pip install twine

npm install -g yarn

REPOS=(stack-client-python stack-client-typescript stack)
if is_truthy "$LLAMA_STACK_ONLY"; then
  REPOS=(stack)
fi

for repo in "${REPOS[@]}"; do
  org=$(github_org $repo)
  git clone "https://x-access-token:${GITHUB_TOKEN}@github.com/$org/llama-$repo.git"
  cd llama-$repo

  echo "Fetching release branch $RELEASE_BRANCH..."
  git fetch origin "$RELEASE_BRANCH":"$RELEASE_BRANCH"
  git checkout "$RELEASE_BRANCH"

  if [ "$repo" == "stack-client-typescript" ]; then
    NPM_VERSION=$(cat package.json | jq -r '.version')
    echo "version to build: $NPM_VERSION"

    npx yarn install
    npx yarn build
  else
    # Build llama_stack_api first if it exists (main package depends on it)
    if [ "$repo" == "stack" ] && [ -d "src/llama_stack_api" ] && [ -f "src/llama_stack_api/pyproject.toml" ]; then
      echo "Building llama_stack_api first (dependency of llama-stack)"
      cd src/llama_stack_api
      uv build -q
      uv pip install dist/*.whl
      cd -
    fi

    PYPROJECT_VERSION=$(cat pyproject.toml | grep version)
    echo "version to build: $PYPROJECT_VERSION"

    uv build -q
    uv pip install dist/*.whl
  fi

  # tag the commit on the branch (will be force-moved after lockfile updates)
  echo "Tagging llama-$repo at version $VERSION (will update after lockfiles)"
  git tag -a "v$VERSION" -m "Release version $VERSION"

  if [ "$repo" == "stack-client-typescript" ]; then
    echo "Uploading llama-$repo to npm"
    cd dist
    # Try to publish, but don't fail if version already exists
    if npx yarn publish --access public --tag rc-$VERSION --registry https://registry.npmjs.org/ 2>&1 | tee /tmp/npm-publish.log; then
      echo "✅ Successfully published to npm"
    elif grep -q "You cannot publish over the previously published versions" /tmp/npm-publish.log; then
      echo "⚠️  Version $VERSION already published to npm, skipping..."
    else
      echo "❌ Failed to publish to npm"
      exit 1
    fi
    cd ..
  else
    echo "Uploading llama-$repo to testpypi"
    # Use OIDC/trusted publishing for main packages
    python -m twine upload \
      --repository-url https://test.pypi.org/legacy/ \
      --skip-existing \
      dist/*.whl dist/*.tar.gz

    # Upload llama_stack_api if it exists (needs token auth)
    if [ "$repo" == "stack" ] && [ -d "src/llama_stack_api" ] && [ -f "src/llama_stack_api/pyproject.toml" ]; then
      echo "Uploading llama_stack_api to testpypi"
      cd src/llama_stack_api
      if [ -n "${TEST_PYPI_TOKEN:-}" ]; then
        # Use token authentication for llama-stack-api (disable command echo)
        set +x
        python -m twine upload \
          --repository-url https://test.pypi.org/legacy/ \
          --username __token__ \
          --password "$TEST_PYPI_TOKEN" \
          --skip-existing \
          dist/*.whl dist/*.tar.gz
        set -x
      else
        # Fallback to OIDC/trusted publishing
        python -m twine upload \
          --repository-url https://test.pypi.org/legacy/ \
          --skip-existing \
          dist/*.whl dist/*.tar.gz
      fi
      cd -
    fi
  fi

  cd ..
done

# Push TypeScript tag immediately since it doesn't need lockfile updates
for repo in "${REPOS[@]}"; do
  if [ "$repo" == "stack-client-typescript" ]; then
    cd llama-$repo
    org=$(github_org $repo)
    echo "Pushing tag for llama-$repo (no lockfile updates needed)"
    git push -f "https://x-access-token:${GITHUB_TOKEN}@github.com/$org/llama-$repo.git" "v$VERSION"
    cd ..
  fi
done

# Update lockfiles now that packages are published to test.pypi
# Force-move tags to include lockfile updates
echo "Updating lockfiles after publishing to test.pypi..."
for repo in "${REPOS[@]}"; do
  if [ "$repo" == "stack-client-typescript" ]; then
    # TypeScript client doesn't need lockfile updates (already pushed above)
    continue
  fi

  cd llama-$repo

  # Install pre-commit if not already available
  if ! command -v pre-commit &> /dev/null; then
    uv pip install pre-commit
  fi

  echo "Running pre-commit to update lockfiles for $repo..."
  run_precommit_lockfile_update

  # Commit lockfile changes if any
  if [ -n "$(git status --porcelain)" ]; then
    git commit -am "chore: update lockfiles for ${VERSION}"
    echo "✅ Lockfiles updated and committed for $repo"

    # Force-move the tag to include the lockfile commit
    echo "Force-moving tag v$VERSION to include lockfiles..."
    git tag -f -a "v$VERSION" -m "Release version $VERSION"
  else
    echo "No lockfile changes for $repo"
  fi

  # Push branch first (to ensure the commit exists on remote)
  # Then push tag (which points to the commit)
  echo "Pushing branch and tag for llama-$repo"
  org=$(github_org $repo)
  git push -f "https://x-access-token:${GITHUB_TOKEN}@github.com/$org/llama-$repo.git" "$RELEASE_BRANCH"
  git push -f "https://x-access-token:${GITHUB_TOKEN}@github.com/$org/llama-$repo.git" "v$VERSION"

  cd ..
done
