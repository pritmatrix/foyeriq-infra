#!/usr/bin/env bash
# Loads local, non-secret config from .env at the repo root (see
# .env.example for the template — copy it to .env and edit). Source this,
# don't execute it directly.
#
# Anything already set in the calling environment wins over .env, so
# ad-hoc overrides (FOO=bar ./script.sh) still work as expected.

load_env() {
  local repo_root="$1" env_file
  env_file="$repo_root/.env"
  [[ -f "$env_file" ]] || return 0
  local line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    key="${line%%=*}"
    value="${line#*=}"
    [[ -z "${!key:-}" ]] && export "$key=$value"
  done < "$env_file"
}
