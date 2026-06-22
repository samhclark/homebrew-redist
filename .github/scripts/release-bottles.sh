#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=publish-bottles.sh
source "$script_dir/publish-bottles.sh"

repo="${GITHUB_REPOSITORY:-}"
ref="${RELEASE_BOTTLES_REF:-main}"
poll_seconds="${RELEASE_BOTTLES_POLL_SECONDS:-15}"
run_appear_timeout_seconds="${RELEASE_BOTTLES_RUN_APPEAR_TIMEOUT_SECONDS:-300}"
test_timeout_seconds="${RELEASE_BOTTLES_TEST_TIMEOUT_SECONDS:-7200}"
publish_timeout_seconds="${RELEASE_BOTTLES_PUBLISH_TIMEOUT_SECONDS:-1800}"

usage() {
  cat >&2 <<'EOS'
usage: release-bottles.sh run <tests-run-id> [changed|formula] [bottles-dir]
       release-bottles.sh plan <tests-run-id> [changed|formula] [bottles-dir]
EOS
}

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

require_repo() {
  [[ -n "$repo" ]] || fail "GITHUB_REPOSITORY is required."
}

append_summary() {
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '%s\n' "$@" >> "$GITHUB_STEP_SUMMARY"
  fi
}

join_words() {
  if [[ "$#" -eq 0 ]]; then
    printf 'none'
    return
  fi

  local output=""
  local word
  for word in "$@"; do
    if [[ -n "$output" ]]; then
      output+=", "
    fi
    output+="$word"
  done
  printf '%s' "$output"
}

contains_word() {
  local needle="$1"
  shift

  local item
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done

  return 1
}

validate_formula_request() {
  local requested="$1"

  case "$requested" in
    changed)
      ;;
    smolvm | smolvm-libkrunfw | smolvm-virglrenderer)
      ;;
    *)
      fail "unknown formula request: $requested"
      ;;
  esac
}

validate_source_run() {
  local run_id="$1"
  local run_json
  run_json="$(gh api "repos/$repo/actions/runs/$run_id")"

  local status
  local conclusion
  local branch
  local path
  local source_sha
  status="$(jq -r .status <<< "$run_json")"
  conclusion="$(jq -r .conclusion <<< "$run_json")"
  branch="$(jq -r .head_branch <<< "$run_json")"
  path="$(jq -r .path <<< "$run_json")"
  source_sha="$(jq -r .head_sha <<< "$run_json")"

  [[ "$status" == "completed" ]] || fail "source run $run_id is not completed; status is $status."
  [[ "$conclusion" == "success" ]] || fail "source run $run_id did not succeed; conclusion is $conclusion."
  [[ "$branch" == "main" ]] || fail "source run $run_id is from $branch, not main."
  [[ "$path" == ".github/workflows/tests.yml" ]] || fail "source run $run_id used $path, not tests.yml."

  if ! git cat-file -e "$source_sha^{commit}" 2>/dev/null; then
    fail "source commit $source_sha is not present in the local checkout."
  fi
  git merge-base --is-ancestor "$source_sha" HEAD ||
    fail "source commit $source_sha is not an ancestor of HEAD."

  printf '%s\n' "$source_sha"
}

changed_formulas_for_source() {
  local source_sha="$1"
  local base
  base="$(git rev-parse "$source_sha^")"
  changed_formulas "$base" "$source_sha"
}

requested_present_formulas() {
  local requested="$1"
  local source_sha="$2"
  local bottles_dir="$3"
  shift 3
  local present_formulae=("$@")

  if [[ "$requested" == "changed" ]]; then
    printf '%s\n' "${present_formulae[@]}"
    return
  fi

  if contains_word "$requested" "${present_formulae[@]}"; then
    printf '%s\n' "$requested"
    return
  fi

  fail "$requested was requested, but no $requested bottles from $source_sha were found in $bottles_dir."
}

delayed_formulas() {
  local requested="$1"
  shift
  local present_count="$1"
  shift
  local changed_count="$1"
  shift
  local present_formulae=("${@:1:present_count}")
  shift "$present_count"
  local changed_formulae=("${@:1:changed_count}")

  [[ "$requested" == "changed" ]] || return 0

  if contains_word "smolvm" "${changed_formulae[@]}" &&
     ! contains_word "smolvm" "${present_formulae[@]}"; then
    printf '%s\n' "smolvm"
  fi
}

latest_run_id() {
  local workflow="$1"
  gh run list \
    --repo "$repo" \
    --workflow "$workflow" \
    --branch "$ref" \
    --limit 1 \
    --json databaseId \
    --jq '.[0].databaseId // 0'
}

wait_for_new_run() {
  local workflow="$1"
  local previous="$2"
  local deadline=$((SECONDS + run_appear_timeout_seconds))
  local run_id

  while (( SECONDS < deadline )); do
    run_id="$(
      gh run list \
        --repo "$repo" \
        --workflow "$workflow" \
        --branch "$ref" \
        --limit 20 \
        --json databaseId \
        --jq "map(select(.databaseId > $previous)) | max_by(.databaseId) | .databaseId // empty"
    )"
    if [[ -n "$run_id" ]]; then
      printf '%s\n' "$run_id"
      return
    fi
    sleep "$poll_seconds"
  done

  fail "timed out waiting for a new $workflow run to appear."
}

wait_for_run_success() {
  local run_id="$1"
  local timeout_seconds="$2"
  local label="$3"
  local deadline=$((SECONDS + timeout_seconds))
  local run_json
  local status
  local conclusion
  local url

  while (( SECONDS < deadline )); do
    run_json="$(gh run view "$run_id" --repo "$repo" --json status,conclusion,url)"
    status="$(jq -r .status <<< "$run_json")"
    conclusion="$(jq -r '.conclusion // ""' <<< "$run_json")"
    url="$(jq -r .url <<< "$run_json")"

    if [[ "$status" == "completed" ]]; then
      if [[ "$conclusion" == "success" ]]; then
        printf '%s succeeded: %s\n' "$label" "$url" >&2
        return
      fi
      fail "$label failed with conclusion $conclusion: $url"
    fi

    printf '%s is %s; waiting...\n' "$label" "$status" >&2
    sleep "$poll_seconds"
  done

  fail "timed out waiting for $label to complete."
}

dispatch_workflow() {
  local workflow="$1"
  shift
  local previous
  previous="$(latest_run_id "$workflow")"
  gh workflow run "$workflow" --repo "$repo" --ref "$ref" "$@" >&2
  wait_for_new_run "$workflow" "$previous"
}

dispatch_publish() {
  local source_run_id="$1"
  local formula="$2"
  local publish_run_id

  printf 'Dispatching publish.yml for %s from run %s.\n' "$formula" "$source_run_id" >&2
  publish_run_id="$(dispatch_workflow publish.yml -f "run_id=$source_run_id" -f "formula=$formula")"
  wait_for_run_success "$publish_run_id" "$publish_timeout_seconds" "publish.yml run $publish_run_id"
  printf '%s\n' "$publish_run_id"
}

dispatch_tests() {
  local formula="$1"
  local tests_run_id

  printf 'Dispatching tests.yml for %s.\n' "$formula" >&2
  tests_run_id="$(dispatch_workflow tests.yml -f "formula=$formula")"
  wait_for_run_success "$tests_run_id" "$test_timeout_seconds" "tests.yml run $tests_run_id"
  printf '%s\n' "$tests_run_id"
}

plan_release() {
  local source_run_id="$1"
  local requested="${2:-changed}"
  local bottles_dir="${3:-bottles}"
  validate_formula_request "$requested"
  require_repo

  local source_sha
  source_sha="$(validate_source_run "$source_run_id")"

  mapfile -t present_formulae < <(present_formulas "$source_sha" "$bottles_dir")
  mapfile -t selected < <(requested_present_formulas "$requested" "$source_sha" "$bottles_dir" "${present_formulae[@]}")
  mapfile -t changed_formulae < <(changed_formulas_for_source "$source_sha")
  mapfile -t delayed < <(delayed_formulas "$requested" "${#present_formulae[@]}" "${#changed_formulae[@]}" "${present_formulae[@]}" "${changed_formulae[@]}")

  [[ "${#selected[@]}" -gt 0 ]] || fail "no bottle artifacts selected for publishing."

  printf 'source_sha=%s\n' "$source_sha"
  printf 'changed=%s\n' "$(join_words "${changed_formulae[@]}")"
  printf 'present=%s\n' "$(join_words "${present_formulae[@]}")"
  printf 'selected=%s\n' "$(join_words "${selected[@]}")"
  printf 'delayed=%s\n' "$(join_words "${delayed[@]}")"
}

run_release() {
  local source_run_id="$1"
  local requested="${2:-changed}"
  local bottles_dir="${3:-bottles}"

  validate_formula_request "$requested"
  require_repo

  local source_sha
  source_sha="$(validate_source_run "$source_run_id")"

  mapfile -t present_formulae < <(present_formulas "$source_sha" "$bottles_dir")
  mapfile -t selected < <(requested_present_formulas "$requested" "$source_sha" "$bottles_dir" "${present_formulae[@]}")
  mapfile -t changed_formulae < <(changed_formulas_for_source "$source_sha")
  mapfile -t delayed < <(delayed_formulas "$requested" "${#present_formulae[@]}" "${#changed_formulae[@]}" "${present_formulae[@]}" "${changed_formulae[@]}")

  [[ "${#selected[@]}" -gt 0 ]] || fail "no bottle artifacts selected for publishing."

  append_summary "### Bottle release plan" ""
  append_summary "- Source run: \`$source_run_id\`"
  append_summary "- Source commit: \`$source_sha\`"
  append_summary "- Changed formulae: \`$(join_words "${changed_formulae[@]}")\`"
  append_summary "- Formulae present in source artifacts: \`$(join_words "${present_formulae[@]}")\`"
  append_summary "- Initial publish selection: \`$(join_words "${selected[@]}")\`"
  append_summary "- Delayed formulae: \`$(join_words "${delayed[@]}")\`" ""

  local first_publish_run
  first_publish_run="$(dispatch_publish "$source_run_id" "$requested")"
  append_summary "- Initial publish run: \`$first_publish_run\`"

  local formula
  local tests_run
  local publish_run
  for formula in "${delayed[@]}"; do
    tests_run="$(dispatch_tests "$formula")"
    publish_run="$(dispatch_publish "$tests_run" "$formula")"
    append_summary "- \`$formula\` test run: \`$tests_run\`"
    append_summary "- \`$formula\` publish run: \`$publish_run\`"
  done
}

cmd="${1:-}"
case "$cmd" in
  plan)
    shift
    [[ "$#" -ge 1 && "$#" -le 3 ]] || {
      usage
      exit 2
    }
    plan_release "$@"
    ;;
  run)
    shift
    [[ "$#" -ge 1 && "$#" -le 3 ]] || {
      usage
      exit 2
    }
    run_release "$@"
    ;;
  *)
    usage
    exit 2
    ;;
esac
