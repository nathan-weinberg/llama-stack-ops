# Copyright (c) Meta Platforms, Inc. and affiliates.
# All rights reserved.
#
# This source code is licensed under the terms described in the LICENSE file in
# the root directory of this source tree.

github_org() {
  echo "llamastack"
}

# Determine if we need to set LLAMA_STACK_TEST_RECORDING_DIR
# Only needed for llama-stack >= 0.4.0 (when src/ layout was introduced)
# For older versions (0.3.x and earlier), the default behavior works fine
should_set_recording_dir() {
  local version=$1

  # Extract major.minor version (remove rc suffix and patch version)
  local base_version=$(echo "$version" | sed 's/rc[0-9]*$//')
  local major=$(echo "$base_version" | cut -d. -f1)
  local minor=$(echo "$base_version" | cut -d. -f2)

  # Check if version >= 0.4.0
  # Dev builds (from main) should also use the new behavior
  if [[ "$version" =~ \.dev[0-9]+$ ]]; then
    return 0  # Dev builds use new structure
  elif [ "$major" -gt 0 ]; then
    return 0  # Major version > 0 uses new structure
  elif [ "$major" -eq 0 ] && [ "$minor" -ge 4 ]; then
    return 0  # 0.4.x and above use new structure
  else
    return 1  # 0.3.x and below use old structure
  fi
}

run_integration_tests() {
  stack_config=$1

  # Only set LLAMA_STACK_TEST_RECORDING_DIR for newer versions (>= 0.4.0)
  # Older versions (0.3.x) have different API structure and don't need this
  if should_set_recording_dir "${VERSION:-0.0.0}"; then
    echo "Setting LLAMA_STACK_TEST_RECORDING_DIR for llama-stack >= 0.4.0"
    export LLAMA_STACK_TEST_RECORDING_DIR="$(pwd)/llama-stack/tests/integration/common"
  else
    echo "Skipping LLAMA_STACK_TEST_RECORDING_DIR for llama-stack < 0.4.0 (using default)"
  fi

  echo "Running integration tests (text)"
  # Run with timeout and capture what's happening when it hangs
  timeout 180 bash -x llama-stack/scripts/integration-tests.sh \
    --stack-config $stack_config \
    --inference-mode replay \
    --suite base \
    --setup ollama || {
      EXIT_CODE=$?
      echo "=== Test script exited with code: $EXIT_CODE ==="
      if [ $EXIT_CODE -eq 124 ]; then
        echo "=== TIMEOUT - Script hung. Checking for hanging processes ==="
        ps aux | grep -E "python|pytest|mcp|node" | grep -v grep
        echo "=== Killing all child processes ==="
        pkill -P $$ || true
      else
        echo "=== Tests failed with exit code $EXIT_CODE ==="
        exit $EXIT_CODE
      fi
    }

  echo "Running integration tests (vision)"
  # Vision tests are usually quick (mostly skipped), 2min timeout
  timeout 120 bash llama-stack/scripts/integration-tests.sh \
    --stack-config $stack_config \
    --inference-mode replay \
    --suite vision \
    --setup ollama || [ $? -eq 124 ]
}

install_dependencies() {
  uv pip install pytest pytest-asyncio

  # Install all dependencies for distribution (includes mcp and other test deps)
  llama stack list-deps starter | xargs -L1 uv pip install
}

test_llama_cli() {
  uv pip list | grep llama
  llama stack list-apis >/dev/null
}
