#!/usr/bin/env bash

# Enable strict mode with specific handling
set -eo pipefail

# Disable debug output for sensitive operations
set +x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/utils.sh"

# Exit on error
# set -e

# Treat unset variables as errors
# set -u

# Unit tests https://github.com/bats-core/bats-core
# Use single quote because `!` is a reserved symbol

is_pre_release=""
latest_tag=""
next_tag=""

# Setup trap for cleanup
cleanup_setup(){
    log_info "Cleaning up temporary files from setup"
    rm -f data.json
    rm -f /tmp/outputs.env
}
trap cleanup_setup EXIT INT TERM

# TODO: WRITE/SAVE ALL RESULTS IN A LOG FILE
# TODO: GENERATE SHA

check_git_tags() {
    log_info "===== Check git tags ======"

    # Check if this is a git repo
    if ! git rev-parse --git-dir > /dev/null 2>&1; then
        handle_error 1 "This is not a git repository!"
    fi

    # Check for tags that starts with "v" (e.g., v0.1.0)
    if [ -z "$(git tag --list "v*")" ]; then
        log_info "No tags found in $REPOSITORY_NAME project, This is likely the first release."
        latest_tag=""
    else
        # Get the most recent tag and remove "v" prefix
        # `git describe --tags --abbrev=0` gets the most recent tag
        # sed removes the "v" prefix from the version number
        # `git describe` only works with annotated tags
        latest_tag=$(git describe --abbrev=0 --tags 2>/dev/null | sed 's/^v//') # Example output 0.1.0

        if [ -n "$latest_tag" ]; then
            log_info "Tags detected in the $REPOSITORY_NAME"
        else
            handle_error 1 "Unable to determine the latest tag."
        fi
    fi

    log_info "latest_tag = $latest_tag"
}

parse_latest_commits() {
    log_info "===== Parse latest commits ======"

    local git_log_cmd
    if [ -n "$latest_tag" ]; then
        log_info "Fetching commits since tag: v${latest_tag}"
        # Get all commits since the latest tag
        git_log_cmd=(git log v"${latest_tag}"..HEAD --pretty=format:'__START__%n%h%n%s%n%b')
    else
        log_info "No tags exist, Fetching all commits"
        # Get all commits since the start
        git_log_cmd=(git log --pretty=format:'__START__%n%h%n%s%n%b')
    fi

    # Create a new json file using jq
    jq -n '{data: []}' >data.json

    # Pipe it to awk
    "${git_log_cmd[@]}" | awk '
    BEGIN {
        RS="";
        FS="\n";
        print "["
    }

    function json_escape(str) {
        if(str == "") return "";
        gsub(/\\/, "\\\\", str);       # Escape backslashes first
        gsub(/"/, "\\\"", str);        # Escape quotes
        gsub(/\//, "\\/", str);        # Escape forward slashes
        gsub(/\t/, "\\t", str);        # Escape tabs
        gsub(/\n/, "\\n", str);        # Escape new lines
        gsub(/\r/ , "\\r", str);       # Escape carriage returns
        gsub(/[\x00-\x1f]/, "", str); # Escape Remove other control characters

        return str;
    }

    {
        if (NR > 1) print ","


        hash = json_escape($2);
        raw_subject = json_escape($3);
        type = ""; scope = ""; breaking = "false"; message = ""; trigger = ""; prerelease = "";

        # Parse Conventional Commit subject
        if (match(raw_subject, /^([a-z]+)(\(([^\)]+)\))?(!)?:[ ]*(.*)$/, parts)) {
            type = json_escape(parts[1]);
            scope = json_escape(parts[3]);
            breaking = (parts[4] == "!") ? "true" : "false";
            trigger = (parts[4] == "!") ? "subject" : "";
            message = json_escape(parts[5]);
        } else {
            message = raw_subject;
        }

        body_lines = "";
        body_count = 0;
        for (i = 4; i <= NF; i++) {
            line = json_escape($i);
            if (line == "") continue;

            if (body_count++ > 0) body_lines = body_lines ",\n";
            body_lines = body_lines "    \"" line "\"";

            if (line ~ /^BREAKING CHANGE:/) {
                breaking = "true";
                trigger = "body"
            }

            if (match(line, /^Pre-Release:[ \t]*([a-zA-Z0-9.-]+)/, pr_parts)) {
                prerelease = json_escape(pr_parts[1]);
            }
        }

        # Ensure all fields are properly quoted and escaped
        printf "  {\n";
        printf "    \"hash\": \"%s\", \n", hash;
        printf "    \"raw_subject\": \"%s\",\n", raw_subject;
        printf "    \"type\": \"%s\",\n", type;
        printf "    \"scope\": \"%s\",\n", scope;
        printf "    \"breaking\": \"%s\",\n", breaking;
        printf "    \"trigger\": \"%s\",\n", trigger;
        printf "    \"prerelease\": \"%s\",\n", prerelease;
        printf "    \"message\": \"%s\",\n", message;
        printf "    \"body_lines\": [\n";
        printf "%s\n", body_lines;
        printf "    ]\n";
        printf "  }";
    }

    END {
        print "]"
    }' | jq '{data: .}' >data.json

    # Validate the generated JSON
    if ! jq empty data.json 2>/dev/null; then
        handle_error 1 "Failed to generate valid data.json from commits"
    fi

    # Validate that data.json has actual content
    data_count=$(jq '.data | length' data.json 2>/dev/null || echo "0")
    if [[ "$data_count" -eq 0 ]]; then
        log_warning "No commits found in the parsed data"
    fi

    # Check for awk errors
    if ! "${git_log_cmd[@]}" >/dev/null 2>&1; then
        handle_error 1 "Failed to fetch git log"
    fi
}

bump_version() {
    log_info "===== Bumping versions ======"

    first_prerelease=$(jq -r '.data[0].prerelease' data.json)

    # Handle first release
    # If latest_tag is empty
    if [[ -z "$latest_tag" ]]; then
        # initial commit | first commit | Initial public release

        case "$first_prerelease" in
        dev|alpha|beta|rc)
            log_warning "Pre-release labels are not allowed for 0.x.x versions. Ignoring '${first_prerelease}'."
            ;;
        esac

        next_tag="0.1.0"
        is_pre_release=true
        log_info "First release: v$next_tag (pre-release)"
        return 0
    fi

    # Parse the current version components
    version_components=$(parse_latest_tag "$latest_tag")
    if ! read -r major minor patch pre_release pre_num <<<"$version_components"; then
        handle_error 1 "Error: Failed to parse current version $latest_tag"
    fi

    # Handle pre-release version bumping
    if [[ -n "$pre_release" && -n "$pre_num" ]]; then
        # We're on a pre-release track, increment the pre-release number
        pre_num=$((pre_num + 1))
        next_tag="$major.$minor.$patch-$pre_release.$pre_num"
        is_pre_release=true
        log_info "Pre-release version bump to: v$next_tag (incrementing $pre_release.$pre_num)"
        log_summary "data.json"
        return 0
    fi

    # Determine version bump based on changes
    # Array size of: ${#breaking_changes[@]}
    breaking_changes_count=$(jq '[.data[] | select(.breaking == "true")] | length' data.json)
    if [[ "${breaking_changes_count}" -ne 0 ]]; then
        # Bump major(major version increment)
        next_tag="$((major + 1)).0.0"

        # Apply pre-release label if specified in commit
        if [[ -n "$first_prerelease" ]]; then
            case $first_prerelease in
                dev|alpha|beta|rc)
                    next_tag="$next_tag-${first_prerelease}.1"
                    is_pre_release=true
                ;;
                *)
                    is_pre_release=false
                ;;
            esac
        else
            is_pre_release=false
        fi

        log_info "Major version bump to: v$next_tag"
        log_info "Breaking changes(${breaking_changes_count}):"
        log_summary "data.json"

        return 0 # Exit/Break this function and move to the next function
    fi

    new_features_count=$(jq '[.data[] | select(.type == "feat")] | length' data.json)
    performance_improvements_count=$(jq '[.data[] | select(.type == "perf")] | length' data.json)
    if [[ "${new_features_count}" -ne 0 || "${performance_improvements_count}" -ne 0 ]]; then
        # Bump minor
        next_tag="$major.$((minor + 1)).0"
        log_info "Minor version bump to: v$next_tag"

        if [[ "$major" -eq 0 ]]; then
            is_pre_release=true
        else
            is_pre_release=false
        fi

        log_info "New Features(${new_features_count})"
        log_info "Performance Improvements: ${performance_improvements_count}"
        log_summary "data.json"

        return 0
    fi

    bug_fixes_count=$(jq '[.data[] | select(.type == "fix")] | length' data.json)
    if [[ "${bug_fixes_count}" -ne 0 ]]; then
        # Bump patch
        next_tag="$major.$minor.$((patch + 1))"
        log_info "Patch version bump to: v$next_tag"

        if [[ "$major" -eq 0 ]]; then
            is_pre_release=true
        else
            is_pre_release=false
        fi

        log_info "Bug Fixes(${bug_fixes_count})"
        log_summary "data.json"

        return 0
    fi

    log_info "No version-impacting changes detected in codebase!"
    log_info "Current version remains at v$latest_tag"
    # next_tag intentionally left empty to signal no release needed
}

update_version_in_config_file(){
    log_info "===== Update version in config file ======"
    get_config_file(){
        # List of config files to check
        # TODO: Remove "config.yaml" later
        files=("config.yaml" "pubspec.yaml" "package.json" "build.gradle" "Info.plist" "composer.json" ".version")

        for file in "${files[@]}"; do
            if [ -f "$file" ]; then
                echo "$file"
                return 0 # Return after finding the FIRST file
            fi
        done
    }

    if [[ -z $latest_tag ]]; then
        return 0
    fi

    config_file=$(get_config_file)

    if [[ "$config_file" == "pubspec.yaml" ]]; then
        version=$(grep '^version:' pubspec.yaml | awk '{print $2}')
        regex='^([0-9]+)\.([0-9]+)\.([0-9]+)\+([0-9]+)$'
        if [[ $version =~ $regex ]]; then
            # Build number
            build="${BASH_REMATCH[4]}"
        fi

        # Increment build number and replace only the version line
        sed -i "s/$version/$next_tag+$((build + 1))/g" "$config_file"
    else
        # For other files
        find_text="version: $latest_tag"
        replace_text="version: $next_tag"
        # Syntax: "s/pattern/replacement/g"
        sed -i "s/$find_text/$replace_text/g" "$config_file"
    fi

    git add "$config_file"

    commit_message="chore: bump version to $next_tag [no ci]"
    git commit -S -m "$commit_message"
    git log --show-signature
    git push -v origin main
}

generate_changelog() {
    log_info "===== Generate changelog ======"

    local latest_changelog
    latest_changelog=$(build_latest_changelog)

    # Clean up any placeholder content
    latest_changelog=$(echo "$latest_changelog" | grep -v "No body content")

    current_date=$(date +%Y-%m-%d)

    # https://chat.openai.com/share/404f983a-046b-4112-a86c-6b3bf0c07be5

    repo_url="https://github.com/$USERNAME/$REPOSITORY_NAME"

    # `-z` means that the variable is empty, `-n` means the variable is not empty
    if [ -z "$latest_tag" ]; then
        # First release create a fresh changelog file
        url="$repo_url/releases/tag/v$next_tag"

        printf '# Changelog\n\n## [%s](%s) (%s)\n\n%s' "$next_tag" "$url" "$current_date" "$latest_changelog" > "CHANGELOG.md"
    elif [ -n "$latest_tag" ]; then
        # Subsequent releases - update existing changelog file
        url="$repo_url/compare/v$latest_tag...v$next_tag"

        # Content for new version, including its heading
        new_version_content="## [$next_tag]($url) ($current_date)\n\n$latest_changelog"

        # Read the existing changelog, skipping the first line ('# Changelog')
        # This prevents duplicating the main header and old entries
        existing_changelog_without_header=$(tail -n +2 "CHANGELOG.md")

        # Reconstruct the changelog: new main header, new version content, then existing content
        {
            printf '# Changelog\n\n'
            printf '%b' "$new_version_content"
            printf '\n'
            printf '%s' "$existing_changelog_without_header"
        } > "CHANGELOG.md"
    fi

    log_info "Changelog created successfully."
}

post_setup() {
    echo '===== post_setup ====='

    # Guard against empty next_tag
    if [[ -z "${next_tag:-}" ]]; then
        log_warning "No version-impacting changes detected. Setting should_release to false."
        {
            echo "is_pre_release=$is_pre_release"
            echo "latest_tag=${latest_tag:-}"
            echo "next_tag=$next_tag"
            echo "should_release=false"
        } >> "$GITHUB_OUTPUT"
    else
        {
            echo "is_pre_release=$is_pre_release"
            echo "latest_tag=$latest_tag"
            echo "next_tag=$next_tag"
            echo "should_release=true"
        } >> "$GITHUB_OUTPUT"
    fi

    log_info "Cleaning up temporary files"
    rm -f data.json
}

# Main execution
validate_environment
setup_git
check_git_tags
parse_latest_commits
bump_version

# Only generate changelog and update version in the config file
if [[ -n "${next_tag:-}" ]]; then
    update_version_in_config_file
    generate_changelog
fi

post_setup
