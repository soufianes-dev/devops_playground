#!/usr/bin/env bash

# Enable strict mode
set -euo pipefail

export TERM=xterm-color
export GPG_TTY=$(tty)

GPG_WRAPPER_PATH=""

# Derive log path from script location or GITHUB_WORKSPACE
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${GITHUB_WORKSPACE:-$SCRIPT_DIR}/release_script.log"
LOG_LEVEL_INFO="INFO"
LOG_LEVEL_WARN="WARN"
LOG_LEVEL_ERROR="ERROR"

# Cleanup function for GPG wrapper
cleanup_gpg_wrapper(){
    if [[ -n "${GPG_WRAPPER_PATH:-}" && -f "$GPG_WRAPPER_PATH" ]]; then
        rm -f "$GPG_WRAPPER_PATH"
        log_info "GPG wrapper cleaned up"
    fi
}

# Logging utility
log() {
    local LOG_LEVEL=$1
    local MESSAGE=$2
    local TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

    case ${LOG_LEVEL} in
    INFO) COLOR="\033[32m" ;;  # Green - fixed escape code
    WARN) COLOR="\033[33m" ;;  # Yellow - fixed escape code
    ERROR) COLOR="\033[31m" ;; # Red - fixed escape code
    *) COLOR="\033[0m" ;;       # No color
    esac

    # Log to both console and file (tee)
    echo -e "${COLOR}[${TIMESTAMP}] [${LOG_LEVEL}] ${MESSAGE}\033[0m" | tee -a "${LOG_FILE}" # Fixed reset code
}

log_info() {
    local info_message=$1
    log "${LOG_LEVEL_INFO}" "$info_message"
}

log_warning() {
    local warning_message=$1
    log "${LOG_LEVEL_WARN}" "$warning_message"
}

handle_error() {
    local error_code=$1
    local error_message=$2

    log "${LOG_LEVEL_ERROR}" "$error_message"

    # Cleanup GPG wrapper if it exists
    if [[ -n "${GPG_WRAPPER_PATH:-}" && -f "$GPG_WRAPPER_PATH" ]];then
        rm -f "$GPG_WRAPPER_PATH"
        log_info "GPG wrapper cleaned up on error"
    fi

    # Clean up data.json if it exists
    [[ -f "data.json" ]] && rm -f "data.json"

    exit "$error_code"
}


if [[ $- == *x* ]]; then
    ORIGINAL_DEBUG_MODE=true
    set +x
fi
setup_git() {
    # Temporarily disable set -x to avoid exposing secrets
    # Ensure debug is off
    { set +x; } 2>/dev/null

    log_info "===== Setup git ======"

    # Detect GPG binary
    local GPG_BIN
    # Get the path of GPG binary dynamically
    GPG_BIN=$(command -v gpg) || {
        handle_error 1 "gpg binary not found!"
    }

    exec 3<<<"$GPG_PASSPHRASE"
    # Import private key using file descriptor
    if ! echo "$GPG_PRIVATE_KEY" | "$GPG_BIN" --batch --yes --no-tty --pinentry-mode loopback --passphrase-fd 3 --import; then
        exec 3<&- # Close file descriptor
        handle_error 1 "Failed to import GPG private key!"
    fi
    exec 3<&- # Close file descriptor

    CURRENT_UMASK=$(umask)
    umask 077
    # Create a secure temporary GPG wrapper script
    GPG_WRAPPER_PATH=$(mktemp /tmp/gpg_wrapper.XXXXXX) || {
        umask "$CURRENT_UMASK"
        handle_error 1 "Failed to create temporary file for GPG wrapper!"
    }
    umask "$CURRENT_UMASK"
    chmod 0700 "$GPG_WRAPPER_PATH"

    # Use printf to avoid passphrase in process list
    # Create wrapper that reads passphrase from file descriptor
    
    # `--no-tty` is an argument used by the GPG program to ensure that GPG does not use the terminal for any input
    
    # shellcheck disable=SC2016
    # Using single quotes for all lines to prevent premature expansion
    printf '%s\n' \
    '#!/usr/bin/env bash' \
    'GPG_BIN=$(command -v gpg)' \
    'PIPE_DIR=$(mktemp -d)' \
    'PIPE_PATH="$PIPE_DIR/passphrase"' \
    'mkfifo "$PIPE_PATH"' \
    'chmod 600 "$PIPE_PATH"' \
    'echo "$GPG_PASSPHRASE" > "$PIPE_PATH" &' \
    '"$GPG_BIN" --batch --no-tty --pinentry-mode loopback --passphrase-file "$PIPE_PATH" "$@"' \
    'exit_code=$?' \
    'rm -rf "$PIPE_DIR"' \
    'exit $exit_code' \
    >"$GPG_WRAPPER_PATH"

    chmod +x "$GPG_WRAPPER_PATH"

    # Set up trap for GPG wrapper cleanup
    trap cleanup_gpg_wrapper EXIT INT TERM

    # Configure Git
    git config --global user.name "$GIT_AUTHOR_NAME"  # Set username
    log "${LOG_LEVEL_INFO}" "Git author name is set"

    # Set email
    git config --global user.email "$GIT_AUTHOR_EMAIL"
    log "${LOG_LEVEL_INFO}" "Git author email is set"

    # Used to sign commits with GPG signing key
    git config --global user.signingkey "$GPG_KEY_ID"
    log "${LOG_LEVEL_INFO}" "GPG signing key configured"

    git config --global commit.gpgsign true
    log "${LOG_LEVEL_INFO}" "GPG signing key enabled"

    git config --global tag.gpgsign true
    log "${LOG_LEVEL_INFO}" "Tag signing enabled"
    git config --global gpg.program "$GPG_WRAPPER_PATH"

    log "${LOG_LEVEL_INFO}" "Git setup complete. ✔️"

    # Verify that GPG wrapper works
    if ! "$GPG_WRAPPER_PATH" --version >/dev/null 2>&1; then
        handle_error 1 "GPG wrapper verification failed"
    fi

    # Re-enable debug output if it was on
    set -x
}

validate_environment() {
    log_info "===== Validate environment ======"

    current_branch=$(git rev-parse --abbrev-ref HEAD)
    if [[ "$current_branch" != "main" ]]; then
        handle_error 1 "Releases must be created from main branch (currently on $current_branch)."
    fi

   
    # Extract dependency installation to separate function
    install_dependencies(){
        if command -v jq &>/dev/null; then
            return 0
        fi
        
        log "${LOG_LEVEL_INFO}" "Installing jq..."
        if ! apt-get update && apt-get install -y jq; then
            handle_error 1 "Failed to install jq. Please install it manually."
        fi
    }

    install_dependencies

    required_commands=(git tee wget sed awk tr cut mapfile mktemp curl jq basename file)

    for cmd in "${required_commands[@]}"; do
        # Verify that a program exist
        if command -v "$cmd" &>/dev/null; then
            log "${LOG_LEVEL_INFO}" "$cmd does exist!"
        else
            handle_error 1 "Error: $cmd does not exist!"
        fi
    done

    log_info "===== Setup Environment Variables ======"

    required_env_vars=(GH_TOKEN GIT_AUTHOR_EMAIL GPG_PRIVATE_KEY GPG_PASSPHRASE GPG_KEY_ID GIT_AUTHOR_NAME USERNAME REPOSITORY_NAME)

    for var in "${required_env_vars[@]}"; do
        # Verify that an environment variable exists
        # Safely check if variable is set
        if [[ -z "${!var:-}" ]]; then
            handle_error 1 "Error: $var is not set!"
        fi
    done

    log "${LOG_LEVEL_INFO}" "All required commands and environment variables are verified! ✔️"
}

# Helper function
# Determine the next version based on changes
parse_latest_tag() {
    local latest_tag="$1"
    local major minor patch

    # TODO: Validate input
    if [ -z "$latest_tag" ]; then
        handle_error 1 "Error: Empty tag provided"
    fi

    # Regex to match: major.minor.patch-prerelease.N
    regex='^([0-9]+)\.([0-9]+)\.([0-9]+)(-([a-zA-Z]+)\.([0-9]+))?$'

    # TODO: Validate semantic version format
    if [[ "$latest_tag" =~ $regex ]]; then
        major="${BASH_REMATCH[1]}"
        minor="${BASH_REMATCH[2]}"
        patch="${BASH_REMATCH[3]}"
        pre_release="${BASH_REMATCH[5]}"
        pre_num="${BASH_REMATCH[6]}"

        # Only output the version components
        # Return components as a string with proper spacing
        echo "${major} ${minor} ${patch} ${pre_release:-} ${pre_num:-}"
        return 0
    else
        handle_error 1 "Error: Invalid semantic version format. Expected 'major.minor.patch-prerelease.N' but got '$latest_tag'"
    fi
}

log_summary(){
    local data_file="${1:-data.json}"
    
    docs_count=$(jq '[.data[] | select(.type == "docs")] | length' "$data_file")
    tests_count=$(jq '[.data[] | select(.type == "tests")] | length' "$data_file")
    chores_count=$(jq '[.data[] | select(.type == "chore")] | length' "$data_file")
    styling_count=$(jq '[.data[] | select(.type == "style")] | length' "$data_file")
    build_count=$(jq '[.data[] | select(.type == "build")] | length' "$data_file")
    ci_count=$(jq '[.data[] | select(.type == "ci")] | length' "$data_file")
    code_refactoring_count=$(jq '[.data[] | select(.type == "refactor")] | length' "$data_file")
    reverts_count=$(jq '[.data[] | select(.type == "revert")] | length' "$data_file")

    log_info "===== Change summary: ====="
    log_info "Documentation(${docs_count}):"
    log_info "Tests(${tests_count}):"
    log_info "Chores(${chores_count})"
    log_info "Styling(${styling_count})"
    log_info "Build(${build_count})"
    log_info "Continuous Integration(${ci_count})"
    log_info "Code Refactoring(${code_refactoring_count})"
    log_info "Reverts(${reverts_count})"
    log_info "==========================="
}

build_latest_changelog() {
    # Helper function to format changelog item consistently
    format_changelog_list_item(){
        local scope="$1"
        local message="$2"
        local body_content="$3"
        local commit_hash="$4"
        local username="$5"
        local repository_name="$6"

        local list_item_text=""
        if [ -n "$scope" ]; then
            list_item_text="* **$scope:** $message"
        else
            list_item_text="* $message"
        fi

        local commit_url="https://github.com/$username/$repository_name/commit/$commit_hash"
        local output="$list_item_text ([#$commit_hash]($commit_url))"

        # Add body lines if the exist
        if [ -n "$body_content" ]; then
            # Skip metadata in commit body
            local skip_pattern="^(Pre-Release:|Closes[[:space:]]|Related to[[:space:]]|Resolves[[:space:]]|Fixes[[:space:]]|Refs[[:space:]]|See also[[:space:]]|BREAKING CHANGE:|Co-authored-by:|Signed-off-by:)"
            # Process each body line with proper indentation
            while IFS= read -r line; do
                if [ -n "$line" ] && [[ ! "$line" =~ $skip_pattern ]]; then
                    output+="\n  $line"
                fi
            done <<< "$body_content"
        fi

        echo "$output"
    }

    if [[ -z "${latest_tag:-}" ]]; then
        echo "initial commit"
        return 0
    fi

    declare -A sections # Associative array to hold content for each changelog section

    # Initialize all possible section keys to empty string to prevent 'inbound variable' error_message
    # if 'set -u' is active and no commits for a specific type are found
    sections["breaking"]=""
    sections["feat"]=""
    sections["perf"]=""
    sections["fix"]=""
    sections["docs"]=""
    sections["test"]=""
    sections["chore"]=""
    sections["style"]=""
    sections["build"]=""
    sections["ci"]=""
    sections["refactor"]=""
    sections["revert"]=""

    # Use absolute path or argument for data.json
    local json_file="${GITHUB_WORKSPACE:-.}/data.json"

    # Accept json_file as parameter if provided
    if [[ -n "${1:-}" ]]; then
        json_file="$1"
    fi

    while read -r commit; do
        # Extract fields safely
        hash=$(echo "$commit" | jq -r '.hash? // ""')
        type=$(echo "$commit" | jq -r '.type? // ""')
        scope=$(echo "$commit" | jq -r '.scope? // ""')
        message=$(echo "$commit" | jq -r '.message? // ""')
        breaking=$(echo "$commit" | jq -r '.breaking? // "false"')
        
        # Extract body lines as an array, join with newlines
        body_content=""
        body_count=$(echo "$commit" | jq '.body_lines? | length // 0')
        if [ "$body_count" -gt 0 ]; then
            body_content=$(echo "$commit" | jq -r '.body_lines[]? // empty' 2>/dev/null)
        fi

        local formatted_item
        formatted_item="$(format_changelog_list_item "$scope" "$message" "$body_content" "$hash" "$USERNAME" "$REPOSITORY_NAME")"

        # Handle BREAKING CHANGES separately as they can exist alongside other types
        if [[ "$breaking" == "true" ]]; then
            sections["breaking"]+="$formatted_item\n"
        fi

        # Process other commit types
        case $type in
            "feat"|"perf"|"fix"|"docs"|"test"|"chore"|"style"|"build"|"ci"|"refactor"|"revert")
                    sections["$type"]+="$formatted_item\n"
                ;;
        esac
    done < <(jq -c '.data[]' "$json_file")

    local final_release_notes=""

    # Define section titles for a cleaner output
    declare -A section_titles=(
        ["breaking"]="### BREAKING CHANGES"
        ["feat"]="### Features"
        ["perf"]="### Performance Improvements"
        ["fix"]="### Bug Fixes"
        ["docs"]="### Documentation"
        ["test"]="### Tests"
        ["chore"]="### Chores"
        ["style"]="### Styling"
        ["build"]="### Build"
        ["ci"]="### Continuous Integration"
        ["refactor"]="### Code Refactoring"
        ["revert"]="### Reverts"
    )

    # Define the order in which sections should appear in the final changelog
    local section_order=("breaking" "feat" "perf" "fix" "docs" "test" "chore" "style" "build" "ci" "refactor" "revert")

    # Iterate through the defined order and append sections only if they have content
    for sec_type in "${section_order[@]}"; do
        if [ -n "${sections[$sec_type]}" ]; then
            # Remove any trailing newlines from the section content
            local clean_content
            clean_content=$(echo -e "${sections[$sec_type]}" | sed -e 's/[[:space:]]*$//')

            # Only add newline between sections, not extra ones within
            if [ -n "$final_release_notes" ]; then
                final_release_notes+="\n\n"
            fi

            final_release_notes+="${section_titles[$sec_type]}\n\n"
            final_release_notes+="$clean_content" # Content already includes newlines from format_changelog_list_item
        fi
    done

    # Trim any trailing whitespace from the final output
    final_release_notes=$(echo -e "$final_release_notes" | sed -e 's/[[:space:]]*$//')

    # This is like a return value
    echo "$final_release_notes"
}