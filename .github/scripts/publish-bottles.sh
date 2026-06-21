#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=formula-inputs.sh
source "$script_dir/formula-inputs.sh"

formula_key() {
  printf 'samhclark/redist/%s\n' "$1"
}

select_formulas() {
  local requested="$1"
  local source_sha="$2"
  local bottles_dir="$3"
  local formula
  declare -A present=()

  shopt -s nullglob
  local json
  for json in "$bottles_dir"/*.bottle.json; do
    while IFS=$'\t' read -r key revision; do
      formula="${key#samhclark/redist/}"
      if [[ "$key" == samhclark/redist/* && "$revision" == "$source_sha" ]]; then
        present["$formula"]=1
      fi
    done < <(jq -r 'to_entries[] | [.key, .value.formula.tap_git_revision] | @tsv' "$json")
  done

  if [[ "$requested" != "changed" ]]; then
    printf '%s\n' "$requested"
    return
  fi

  for formula in "${FORMULAS[@]}"; do
    if [[ "${present[$formula]:-}" == 1 ]]; then
      printf '%s\n' "$formula"
    fi
  done
}

validate_formula_inputs_unchanged() {
  local source_sha="$1"
  local formula="$2"

  if formula_input_changed "$source_sha" HEAD "$formula"; then
    printf 'Formula inputs changed after run for %s; publish a newer tests.yml run.\n' "$formula" >&2
    return 1
  fi
}

validate_formula_bottles() {
  local source_sha="$1"
  local bottles_dir="$2"
  local formula="$3"
  local key
  local expected_count
  local expected_tags
  key="$(formula_key "$formula")"
  expected_count="$(formula_expected_count "$formula")"
  expected_tags="$(formula_expected_tags "$formula")"

  shopt -s nullglob
  local jsons=()
  local json
  for json in "$bottles_dir"/*.bottle.json; do
    if jq -e --arg formula "$key" 'has($formula)' "$json" >/dev/null; then
      jsons+=("$json")
    fi
  done

  if [[ "${#jsons[@]}" -ne "$expected_count" ]]; then
    printf '%s expected %s bottle JSON files, found %s.\n' "$formula" "$expected_count" "${#jsons[@]}" >&2
    return 1
  fi

  local archives=()
  local archive
  while IFS= read -r archive; do
    archives+=("$archive")
  done < <(jq -r --arg formula "$key" '.[$formula].bottle.tags[].local_filename' "${jsons[@]}")

  if [[ "${#archives[@]}" -ne "$expected_count" ]]; then
    printf '%s expected %s bottle archives, found %s in JSON.\n' "$formula" "$expected_count" "${#archives[@]}" >&2
    return 1
  fi

  local archive_path
  for archive in "${archives[@]}"; do
    archive_path="$bottles_dir/$archive"
    if [[ ! -f "$archive_path" ]]; then
      printf '%s references missing bottle archive: %s\n' "$formula" "$archive" >&2
      return 1
    fi
  done

  local revisions
  revisions="$(jq -r --arg formula "$key" '.[$formula].formula.tap_git_revision' "${jsons[@]}" | sort -u)"
  if [[ "$revisions" != "$source_sha" ]]; then
    printf '%s bottle revision mismatch. expected %s, got:\n%s\n' "$formula" "$source_sha" "$revisions" >&2
    return 1
  fi

  local formulae
  formulae="$(jq -r 'keys[]' "${jsons[@]}" | sort -u)"
  if [[ "$formulae" != "$key" ]]; then
    printf '%s bottle JSON key mismatch. expected %s, got:\n%s\n' "$formula" "$key" "$formulae" >&2
    return 1
  fi

  local tags
  tags="$(jq -r --arg formula "$key" '.[$formula].bottle.tags | keys[]' "${jsons[@]}" | sort | xargs)"
  if [[ "$tags" != "$expected_tags" ]]; then
    printf '%s bottle tags mismatch. expected "%s", got "%s".\n' "$formula" "$expected_tags" "$tags" >&2
    return 1
  fi

  local root_urls
  root_urls="$(jq -r --arg formula "$key" '.[$formula].bottle.root_url' "${jsons[@]}" | sort -u)"
  if [[ "$(wc -l <<<"$root_urls" | tr -d ' ')" -ne 1 ||
        "$root_urls" != https://github.com/"$GITHUB_REPOSITORY"/releases/download/"$formula"-* ]]; then
    printf '%s bottle root_url mismatch:\n%s\n' "$formula" "$root_urls" >&2
    return 1
  fi
}

publish_formula() {
  local source_sha="$1"
  local bottles_dir="$2"
  local formula="$3"
  local key
  key="$(formula_key "$formula")"

  validate_formula_inputs_unchanged "$source_sha" "$formula"
  validate_formula_bottles "$source_sha" "$bottles_dir" "$formula"

  rm -f ./*.bottle.json ./*.bottle*.tar.gz

  local json
  for json in "$bottles_dir"/*.bottle.json; do
    if jq -e --arg formula "$key" 'has($formula)' "$json" >/dev/null; then
      cp "$json" .
    fi
  done

  local archive
  while IFS= read -r archive; do
    cp "$bottles_dir/$archive" .
  done < <(jq -r --arg formula "$key" '.[$formula].bottle.tags[].local_filename' ./*.bottle.json)

  printf 'Publishing %s bottles from %s.\n' "$formula" "$source_sha"
  brew pr-upload --debug
  rm -f ./*.bottle.json ./*.bottle*.tar.gz
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  cmd="${1:-}"
  case "$cmd" in
    select)
      select_formulas "$2" "$3" "$4"
      ;;
    publish)
      source_sha="$2"
      bottles_dir="$3"
      shift 3
      if [[ "$#" -eq 0 ]]; then
        printf 'no formulas selected for publishing\n' >&2
        exit 1
      fi
      for formula in "$@"; do
        publish_formula "$source_sha" "$bottles_dir" "$formula"
      done
      ;;
    *)
      printf 'usage: %s {select|publish} ...\n' "$0" >&2
      exit 2
      ;;
  esac
fi
