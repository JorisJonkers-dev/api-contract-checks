#!/usr/bin/env bash
set -euo pipefail

program=${0##*/}

usage() {
  cat <<'USAGE'
Usage:
  api-contract-checks.sh --profile <name> --spec-path <path> \
    --export-command <command> [--spec-normalize-command <command>] \
    [--types-path <path> ... | --types-paths <newline-or-comma-list>] \
    [--types-generate-command <command>] \
    [--types-normalize-command <command>] \
    [--breaking-check true|false] \
    [--breaking-base-ref <git-ref>] \
    [--breaking-base-spec-path <path>] \
    [--breaking-fail-on WARN|ERR] \
    [--oasdiff-version <version>] \
    --guidance <command-or-note>

  api-contract-checks.sh --profile-file <file> [--profile-file <file> ...]
  api-contract-checks.sh --profiles-dir <dir> [--only <profile> ...]

Profile files are Bash fragments with these fields:
  PROFILE_NAME
  SPEC_PATH
  SPEC_EXPORT_COMMAND
  SPEC_NORMALIZE_COMMAND       optional
  TYPES_PATHS=(path ...)
  TYPES_PATHS_TEXT             optional newline-or-comma list
  TYPES_GENERATE_COMMAND       optional when TYPES_PATHS is empty
  TYPES_NORMALIZE_COMMAND      optional
  BREAKING_CHECK               optional true|false, default false
  BREAKING_BASE_REF            optional git ref containing the previous spec
  BREAKING_BASE_SPEC_PATH      optional previous spec file path
  BREAKING_FAIL_ON             optional WARN|ERR, default ERR
  OASDIFF_VERSION              optional oasdiff version, default 1.20.0
  GUIDANCE
USAGE
}

trim() {
  local value=$1
  value=${value#"${value%%[![:space:]]*}"}
  value=${value%"${value##*[![:space:]]}"}
  printf '%s' "$value"
}

append_csv() {
  local raw=$1
  local target_name=$2
  # shellcheck disable=SC2178
  local -n target="$target_name"
  local part
  local -a parts=()

  IFS=',' read -r -a parts <<<"$raw"
  for part in "${parts[@]}"; do
    part=$(trim "$part")
    if [[ -n $part ]]; then
      target+=("$part")
    fi
  done
}

append_paths_text() {
  local raw=${1//$'\r'/}
  local target_name=$2
  # shellcheck disable=SC2178
  local -n target="$target_name"
  local line

  if [[ $raw == *$'\n'* ]]; then
    while IFS= read -r line || [[ -n $line ]]; do
      line=$(trim "$line")
      if [[ -n $line ]]; then
        target+=("$line")
      fi
    done <<<"$raw"
  else
    append_csv "$raw" "$target_name"
  fi
}

github_escape() {
  local value=$1
  value=${value//%/%25}
  value=${value//$'\r'/%0D}
  value=${value//$'\n'/%0A}
  printf '%s' "$value"
}

emit_github_error() {
  local path=$1
  local message=$2

  if [[ ${GITHUB_ACTIONS:-} != "true" ]]; then
    return 0
  fi

  if [[ -n $path ]]; then
    printf '::error file=%s::%s\n' "$(github_escape "$path")" "$(github_escape "$message")"
  else
    printf '::error::%s\n' "$(github_escape "$message")"
  fi
}

print_failure() {
  local profile=$1
  local stage=$2
  local path=$3
  local message=$4
  local guidance=$5

  printf '\ncontract check failure\n'
  printf 'profile: %s\n' "$profile"
  printf 'stage: %s\n' "$stage"
  if [[ -n $path ]]; then
    printf 'path: %s\n' "$path"
  fi
  printf 'message: %s\n' "$message"
  if [[ -n $guidance ]]; then
    printf 'guidance: %s\n' "$guidance"
  fi

  emit_github_error "$path" "$profile $stage: $message"
}

snapshot_path() {
  local path=$1
  local snapshot_root=$2
  local profile=$3
  local stage=$4
  local guidance=$5
  local snapshot_path=$snapshot_root/$path

  if [[ ! -e $path ]]; then
    print_failure "$profile" "$stage" "$path" "committed path is missing" "$guidance"
    return 1
  fi

  mkdir -p -- "$(dirname -- "$snapshot_path")"
  if [[ -d $path ]]; then
    mkdir -p -- "$snapshot_path"
    cp -a -- "$path"/. "$snapshot_path"/
  else
    cp -- "$path" "$snapshot_path"
  fi
}

snapshot_paths() {
  local snapshot_root=$1
  local profile=$2
  local stage=$3
  local guidance=$4
  shift 4

  local status=0
  local path
  for path in "$@"; do
    if ! snapshot_path "$path" "$snapshot_root" "$profile" "$stage" "$guidance"; then
      status=1
    fi
  done
  return "$status"
}

run_declared_command() {
  local profile=$1
  local stage=$2
  local command=$3
  local spec_path=$4
  local types_paths_text=$5

  printf '\ncontract check command\n'
  printf 'profile: %s\n' "$profile"
  printf 'stage: %s\n' "$stage"
  printf 'command: %s\n' "$command"

  CONTRACT_PROFILE=$profile \
    CONTRACT_STAGE=$stage \
    CONTRACT_SPEC_PATH=$spec_path \
    CONTRACT_TYPES_PATHS=$types_paths_text \
    bash -euo pipefail -c "$command"
}

compare_path() {
  local path=$1
  local snapshot_root=$2
  local profile=$3
  local stage=$4
  local guidance=$5
  local snapshot_path=$snapshot_root/$path

  if [[ ! -e $path ]]; then
    print_failure "$profile" "$stage" "$path" "generated path is missing after command" "$guidance"
    return 1
  fi

  if diff -ruN -- "$snapshot_path" "$path"; then
    return 0
  fi

  print_failure "$profile" "$stage" "$path" "contract drift detected" "$guidance"
  return 1
}

compare_paths() {
  local snapshot_root=$1
  local profile=$2
  local stage=$3
  local guidance=$4
  shift 4

  local status=0
  local path
  for path in "$@"; do
    if ! compare_path "$path" "$snapshot_root" "$profile" "$stage" "$guidance"; then
      status=1
    fi
  done
  return "$status"
}

ensure_git_ref_available() {
  local ref=$1
  local branch

  if git rev-parse --verify --quiet "${ref}^{commit}" >/dev/null; then
    return 0
  fi

  if [[ $ref == origin/* ]]; then
    branch=${ref#origin/}
    git fetch --depth=1 origin "$branch" >/dev/null 2>&1 || true
  fi

  git rev-parse --verify --quiet "${ref}^{commit}" >/dev/null
}

resolve_breaking_base_ref() {
  local explicit_ref=$1

  if [[ -n $explicit_ref ]]; then
    printf '%s' "$explicit_ref"
  elif [[ -n ${GITHUB_BASE_REF:-} ]]; then
    printf 'origin/%s' "${GITHUB_BASE_REF}"
  else
    printf 'origin/main'
  fi
}

snapshot_breaking_base() {
  local spec_path=$1
  local breaking_base_ref=$2
  local breaking_base_spec_path=$3
  local destination=$4
  local profile=$5
  local guidance=$6
  local resolved_ref

  mkdir -p -- "$(dirname -- "$destination")"

  if [[ -n $breaking_base_spec_path ]]; then
    if [[ ! -f $breaking_base_spec_path ]]; then
      print_failure "$profile" "breaking-change" "$breaking_base_spec_path" "breaking base spec is missing" "$guidance"
      return 1
    fi
    cp -- "$breaking_base_spec_path" "$destination"
    return 0
  fi

  if ! command -v git >/dev/null 2>&1; then
    print_failure "$profile" "breaking-change" "$spec_path" "git is required when breaking-base-spec-path is not set" "$guidance"
    return 1
  fi

  resolved_ref=$(resolve_breaking_base_ref "$breaking_base_ref")
  if ! ensure_git_ref_available "$resolved_ref"; then
    print_failure "$profile" "breaking-change" "$spec_path" "unable to resolve breaking base ref: ${resolved_ref}" "$guidance"
    return 1
  fi

  if ! git show "${resolved_ref}:${spec_path}" >"$destination"; then
    print_failure "$profile" "breaking-change" "$spec_path" "unable to read base spec from ${resolved_ref}:${spec_path}" "$guidance"
    return 1
  fi
}

install_oasdiff() {
  local version=$1
  local install_dir=$2

  mkdir -p -- "$install_dir"

  if [[ -n ${OASDIFF_BIN:-} ]]; then
    if [[ ! -x $OASDIFF_BIN ]]; then
      printf 'OASDIFF_BIN is not executable: %s\n' "$OASDIFF_BIN" >&2
      return 1
    fi
    cp -- "$OASDIFF_BIN" "$install_dir/oasdiff"
    chmod +x -- "$install_dir/oasdiff"
    return 0
  fi

  curl -fsSL https://raw.githubusercontent.com/oasdiff/oasdiff/main/install.sh \
    | INSTALL_DIR="$install_dir" version="$version" sh
}

run_breaking_check() {
  local profile=$1
  local spec_path=$2
  local base_snapshot=$3
  local breaking_fail_on=$4
  local oasdiff_version=$5
  local install_dir=$6
  local guidance=$7

  printf '\ncontract check command\n'
  printf 'profile: %s\n' "$profile"
  printf 'stage: breaking-change\n'
  printf 'command: oasdiff breaking %s %s --fail-on %s --format text\n' "$base_snapshot" "$spec_path" "$breaking_fail_on"

  if ! install_oasdiff "$oasdiff_version" "$install_dir"; then
    print_failure "$profile" "breaking-change" "$spec_path" "oasdiff installation failed" "$guidance"
    return 1
  fi

  if "$install_dir/oasdiff" breaking "$base_snapshot" "$spec_path" --fail-on "$breaking_fail_on" --format text; then
    return 0
  fi

  print_failure "$profile" "breaking-change" "$spec_path" "breaking OpenAPI change detected" "$guidance"
  return 1
}

types_paths_as_text() {
  local path
  for path in "$@"; do
    printf '%s\n' "$path"
  done
}

should_run_profile() {
  local profile=$1
  shift
  local requested

  if [[ $# -eq 0 ]]; then
    return 0
  fi

  for requested in "$@"; do
    if [[ $profile == "$requested" ]]; then
      return 0
    fi
  done

  return 1
}

run_profile() {
  local profile=$1
  local spec_path=$2
  local spec_export_command=$3
  local spec_normalize_command=$4
  local types_generate_command=$5
  local types_normalize_command=$6
  local guidance=$7
  local breaking_check=${8:-false}
  local breaking_base_ref=${9:-}
  local breaking_base_spec_path=${10:-}
  local breaking_fail_on=${11:-ERR}
  local oasdiff_version=${12:-1.20.0}
  shift 12
  local -a types_paths=("$@")

  local status=0
  local spec_snapshot_ok=1
  local types_snapshot_ok=1
  local breaking_base_ok=1
  local spec_export_ok=1
  local tmp_dir
  local spec_snapshot
  local types_snapshot
  local breaking_base_snapshot
  local oasdiff_install_dir
  local types_paths_text

  if [[ -z $profile ]]; then
    print_failure "<unset>" "configuration" "" "PROFILE_NAME is required" ""
    return 1
  fi
  if [[ -z $spec_path ]]; then
    print_failure "$profile" "configuration" "" "SPEC_PATH is required" "$guidance"
    return 1
  fi
  if [[ -z $spec_export_command ]]; then
    print_failure "$profile" "configuration" "$spec_path" "SPEC_EXPORT_COMMAND is required" "$guidance"
    return 1
  fi
  if [[ -z $guidance ]]; then
    print_failure "$profile" "configuration" "$spec_path" "GUIDANCE is required" ""
    return 1
  fi
  if [[ ${#types_paths[@]} -gt 0 && -z $types_generate_command ]]; then
    print_failure "$profile" "configuration" "" "TYPES_GENERATE_COMMAND is required when TYPES_PATHS is set" "$guidance"
    return 1
  fi
  if [[ ${#types_paths[@]} -eq 0 && -n $types_generate_command ]]; then
    print_failure "$profile" "configuration" "" "TYPES_PATHS is required when TYPES_GENERATE_COMMAND is set" "$guidance"
    return 1
  fi
  if [[ $breaking_check != "true" && $breaking_check != "false" ]]; then
    print_failure "$profile" "configuration" "$spec_path" "BREAKING_CHECK must be true or false" "$guidance"
    return 1
  fi
  if [[ $breaking_fail_on != "WARN" && $breaking_fail_on != "ERR" ]]; then
    print_failure "$profile" "configuration" "$spec_path" "BREAKING_FAIL_ON must be WARN or ERR" "$guidance"
    return 1
  fi
  if [[ $breaking_check == "true" && -z $oasdiff_version ]]; then
    print_failure "$profile" "configuration" "$spec_path" "OASDIFF_VERSION is required when BREAKING_CHECK is true" "$guidance"
    return 1
  fi

  tmp_dir=$(mktemp -d)
  spec_snapshot=$tmp_dir/spec
  types_snapshot=$tmp_dir/types
  breaking_base_snapshot=$tmp_dir/base-openapi.json
  oasdiff_install_dir=$tmp_dir/bin
  mkdir -p -- "$spec_snapshot" "$types_snapshot"

  printf '\ncontract check profile\n'
  printf 'profile: %s\n' "$profile"

  if ! snapshot_paths "$spec_snapshot" "$profile" "openapi-spec" "$guidance" "$spec_path"; then
    spec_snapshot_ok=0
    status=1
  fi

  if [[ $breaking_check == "true" ]]; then
    if ! snapshot_breaking_base "$spec_path" "$breaking_base_ref" "$breaking_base_spec_path" "$breaking_base_snapshot" "$profile" "$guidance"; then
      breaking_base_ok=0
      status=1
    fi
  fi

  types_paths_text=$(types_paths_as_text "${types_paths[@]}")

  if ! run_declared_command "$profile" "openapi-spec" "$spec_export_command" "$spec_path" "$types_paths_text"; then
    print_failure "$profile" "openapi-spec" "$spec_path" "export command failed" "$guidance"
    spec_export_ok=0
    status=1
  elif [[ -n $spec_normalize_command ]]; then
    if ! run_declared_command "$profile" "openapi-spec-normalize" "$spec_normalize_command" "$spec_path" "$types_paths_text"; then
      print_failure "$profile" "openapi-spec" "$spec_path" "normalization command failed" "$guidance"
      spec_export_ok=0
      status=1
    fi
  fi

  if [[ $spec_snapshot_ok -eq 1 ]]; then
    if ! compare_paths "$spec_snapshot" "$profile" "openapi-spec" "$guidance" "$spec_path"; then
      status=1
    fi
  fi

  if [[ $breaking_check == "true" && $breaking_base_ok -eq 1 && $spec_export_ok -eq 1 ]]; then
    if ! run_breaking_check "$profile" "$spec_path" "$breaking_base_snapshot" "$breaking_fail_on" "$oasdiff_version" "$oasdiff_install_dir" "$guidance"; then
      status=1
    fi
  fi

  if [[ ${#types_paths[@]} -gt 0 ]]; then
    if ! snapshot_paths "$types_snapshot" "$profile" "types" "$guidance" "${types_paths[@]}"; then
      types_snapshot_ok=0
      status=1
    fi

    if ! run_declared_command "$profile" "types" "$types_generate_command" "$spec_path" "$types_paths_text"; then
      print_failure "$profile" "types" "${types_paths[0]}" "type generation command failed" "$guidance"
      status=1
    elif [[ -n $types_normalize_command ]]; then
      if ! run_declared_command "$profile" "types-normalize" "$types_normalize_command" "$spec_path" "$types_paths_text"; then
        print_failure "$profile" "types" "${types_paths[0]}" "normalization command failed" "$guidance"
        status=1
      fi
    fi

    if [[ $types_snapshot_ok -eq 1 ]]; then
      if ! compare_paths "$types_snapshot" "$profile" "types" "$guidance" "${types_paths[@]}"; then
        status=1
      fi
    fi
  fi

  rm -rf -- "$tmp_dir"

  if [[ $status -eq 0 ]]; then
    printf '\ncontract check passed\n'
    printf 'profile: %s\n' "$profile"
  fi

  return "$status"
}

load_profile_file() {
  local file=$1
  shift
  local -a only_names=("$@")
  local PROFILE_NAME=""
  local SPEC_PATH=""
  local SPEC_EXPORT_COMMAND=""
  local SPEC_NORMALIZE_COMMAND=""
  local TYPES_GENERATE_COMMAND=""
  local TYPES_NORMALIZE_COMMAND=""
  local TYPES_PATHS_TEXT=""
  local BREAKING_CHECK="false"
  local BREAKING_BASE_REF=""
  local BREAKING_BASE_SPEC_PATH=""
  local BREAKING_FAIL_ON="ERR"
  local OASDIFF_VERSION="1.20.0"
  local GUIDANCE=""
  local -a TYPES_PATHS=()

  PROFILE_SELECTED=0

  if [[ ! -f $file ]]; then
    print_failure "<unset>" "configuration" "$file" "profile file is missing" ""
    return 2
  fi

  # shellcheck source=/dev/null
  source "$file"

  if [[ -n $TYPES_PATHS_TEXT ]]; then
    append_paths_text "$TYPES_PATHS_TEXT" TYPES_PATHS
  fi

  if ! should_run_profile "$PROFILE_NAME" "${only_names[@]}"; then
    return 0
  fi

  PROFILE_SELECTED=1

  run_profile \
    "$PROFILE_NAME" \
    "$SPEC_PATH" \
    "$SPEC_EXPORT_COMMAND" \
    "$SPEC_NORMALIZE_COMMAND" \
    "$TYPES_GENERATE_COMMAND" \
    "$TYPES_NORMALIZE_COMMAND" \
    "$GUIDANCE" \
    "$BREAKING_CHECK" \
    "$BREAKING_BASE_REF" \
    "$BREAKING_BASE_SPEC_PATH" \
    "$BREAKING_FAIL_ON" \
    "$OASDIFF_VERSION" \
    "${TYPES_PATHS[@]}"
}

require_value() {
  local flag=$1
  local value=${2:-}

  if [[ -z $value ]]; then
    printf '%s: %s requires a value\n' "$program" "$flag" >&2
    exit 2
  fi
}

main() {
  local direct_profile=""
  local direct_spec_path=""
  local direct_export_command=""
  local direct_spec_normalize_command=""
  local direct_types_generate_command=""
  local direct_types_normalize_command=""
  local direct_guidance=""
  local direct_breaking_check="false"
  local direct_breaking_base_ref=""
  local direct_breaking_base_spec_path=""
  local direct_breaking_fail_on="ERR"
  local direct_oasdiff_version="1.20.0"
  local profiles_dir=""
  local has_direct=0
  local matched_count=0
  local selected_count=0
  local status=0
  local file
  local arg
  local -a direct_types_paths=()
  local -a profile_files=()
  local -a only_names=()

  while [[ $# -gt 0 ]]; do
    arg=$1
    case "$arg" in
      --help|-h)
        usage
        exit 0
        ;;
      --profile-file)
        require_value "$arg" "${2:-}"
        profile_files+=("$2")
        shift 2
        ;;
      --profiles-dir)
        require_value "$arg" "${2:-}"
        profiles_dir=$2
        shift 2
        ;;
      --only)
        require_value "$arg" "${2:-}"
        append_paths_text "$2" only_names
        shift 2
        ;;
      --profile)
        require_value "$arg" "${2:-}"
        direct_profile=$2
        has_direct=1
        shift 2
        ;;
      --spec-path)
        require_value "$arg" "${2:-}"
        direct_spec_path=$2
        has_direct=1
        shift 2
        ;;
      --export-command)
        require_value "$arg" "${2:-}"
        direct_export_command=$2
        has_direct=1
        shift 2
        ;;
      --spec-normalize-command)
        require_value "$arg" "${2:-}"
        direct_spec_normalize_command=$2
        has_direct=1
        shift 2
        ;;
      --types-path)
        require_value "$arg" "${2:-}"
        direct_types_paths+=("$2")
        has_direct=1
        shift 2
        ;;
      --types-paths)
        require_value "$arg" "${2:-}"
        append_paths_text "$2" direct_types_paths
        has_direct=1
        shift 2
        ;;
      --types-generate-command)
        require_value "$arg" "${2:-}"
        direct_types_generate_command=$2
        has_direct=1
        shift 2
        ;;
      --types-normalize-command)
        require_value "$arg" "${2:-}"
        direct_types_normalize_command=$2
        has_direct=1
        shift 2
        ;;
      --guidance)
        require_value "$arg" "${2:-}"
        direct_guidance=$2
        has_direct=1
        shift 2
        ;;
      --breaking-check)
        require_value "$arg" "${2:-}"
        direct_breaking_check=$2
        has_direct=1
        shift 2
        ;;
      --breaking-base-ref)
        require_value "$arg" "${2:-}"
        direct_breaking_base_ref=$2
        has_direct=1
        shift 2
        ;;
      --breaking-base-spec-path)
        require_value "$arg" "${2:-}"
        direct_breaking_base_spec_path=$2
        has_direct=1
        shift 2
        ;;
      --breaking-fail-on)
        require_value "$arg" "${2:-}"
        direct_breaking_fail_on=$2
        has_direct=1
        shift 2
        ;;
      --oasdiff-version)
        require_value "$arg" "${2:-}"
        direct_oasdiff_version=$2
        has_direct=1
        shift 2
        ;;
      *)
        printf '%s: unknown argument: %s\n' "$program" "$arg" >&2
        usage >&2
        exit 2
        ;;
    esac
  done

  if [[ -n $profiles_dir ]]; then
    if [[ ! -d $profiles_dir ]]; then
      printf '%s: profiles directory is missing: %s\n' "$program" "$profiles_dir" >&2
      exit 2
    fi
    shopt -s nullglob
    for file in "$profiles_dir"/*.conf "$profiles_dir"/*.profile; do
      profile_files+=("$file")
    done
    shopt -u nullglob
  fi

  if [[ $has_direct -eq 1 && ${#profile_files[@]} -gt 0 ]]; then
    printf '%s: direct profile flags cannot be combined with profile files\n' "$program" >&2
    exit 2
  fi

  if [[ $has_direct -eq 0 && ${#profile_files[@]} -eq 0 ]]; then
    usage >&2
    exit 2
  fi

  if [[ $has_direct -eq 1 ]]; then
    run_profile \
      "$direct_profile" \
      "$direct_spec_path" \
      "$direct_export_command" \
      "$direct_spec_normalize_command" \
      "$direct_types_generate_command" \
      "$direct_types_normalize_command" \
      "$direct_guidance" \
      "$direct_breaking_check" \
      "$direct_breaking_base_ref" \
      "$direct_breaking_base_spec_path" \
      "$direct_breaking_fail_on" \
      "$direct_oasdiff_version" \
      "${direct_types_paths[@]}"
    exit $?
  fi

  for file in "${profile_files[@]}"; do
    if load_profile_file "$file" "${only_names[@]}"; then
      :
    else
      status=1
    fi
    if [[ ${PROFILE_SELECTED:-0} -eq 1 ]]; then
      selected_count=$((selected_count + 1))
    fi
    matched_count=$((matched_count + 1))
  done

  if [[ $matched_count -eq 0 ]]; then
    printf '%s: no profile files found\n' "$program" >&2
    exit 2
  fi

  if [[ ${#only_names[@]} -gt 0 && $selected_count -eq 0 ]]; then
    printf '%s: no selected profiles matched: %s\n' "$program" "${only_names[*]}" >&2
    exit 2
  fi

  exit "$status"
}

main "$@"
