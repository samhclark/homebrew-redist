#!/usr/bin/env bash
set -euo pipefail

FORMULAS=(smolvm-virglrenderer smolvm-libkrunfw smolvm)

formula_path() {
  case "$1" in
    smolvm) printf '%s\n' "Formula/smolvm.rb" ;;
    smolvm-libkrunfw) printf '%s\n' "Formula/smolvm-libkrunfw.rb" ;;
    smolvm-virglrenderer) printf '%s\n' "Formula/smolvm-virglrenderer.rb" ;;
    *)
      printf 'unknown formula: %s\n' "$1" >&2
      return 1
      ;;
  esac
}

formula_expected_tags() {
  case "$1" in
    smolvm) printf '%s\n' "arm64_linux arm64_tahoe x86_64_linux" ;;
    smolvm-libkrunfw) printf '%s\n' "arm64_tahoe" ;;
    smolvm-virglrenderer) printf '%s\n' "arm64_linux x86_64_linux" ;;
    *)
      printf 'unknown formula: %s\n' "$1" >&2
      return 1
      ;;
  esac
}

formula_expected_count() {
  formula_expected_tags "$1" | wc -w | tr -d ' '
}

strip_bottle_block() {
  awk '
    !skipping && /^[[:space:]]*bottle do[[:space:]]*$/ {
      skipping = 1
      next
    }
    skipping && /^[[:space:]]*end[[:space:]]*$/ {
      skipping = 0
      next
    }
    !skipping {
      print
    }
  '
}

normalized_formula_at_ref() {
  local ref="$1"
  local formula="$2"
  local path
  path="$(formula_path "$formula")"

  if git cat-file -e "$ref:$path" 2>/dev/null; then
    git show "$ref:$path" | strip_bottle_block | sed '/^[[:space:]]*$/d'
  else
    printf '__missing_formula__ %s\n' "$path"
  fi
}

formula_input_changed() {
  local base="$1"
  local head="$2"
  local formula="$3"
  local before
  local after
  before="$(mktemp)"
  after="$(mktemp)"

  normalized_formula_at_ref "$base" "$formula" >"$before"
  normalized_formula_at_ref "$head" "$formula" >"$after"

  if cmp -s "$before" "$after"; then
    rm -f "$before" "$after"
    return 1
  fi

  rm -f "$before" "$after"
  return 0
}

changed_formulas() {
  local base="$1"
  local head="$2"
  local formula

  for formula in "${FORMULAS[@]}"; do
    if formula_input_changed "$base" "$head" "$formula"; then
      printf '%s\n' "$formula"
    fi
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  cmd="${1:-}"
  case "$cmd" in
    changed)
      changed_formulas "$2" "$3"
      ;;
    expected-count)
      formula_expected_count "$2"
      ;;
    expected-tags)
      formula_expected_tags "$2"
      ;;
    input-changed)
      formula_input_changed "$2" "$3" "$4"
      ;;
    path)
      formula_path "$2"
      ;;
    *)
      printf 'usage: %s {changed|expected-count|expected-tags|input-changed|path} ...\n' "$0" >&2
      exit 2
      ;;
  esac
fi
