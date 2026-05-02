#!/usr/bin/env bash

# Only enable debug output for non-sensitive operations
# set -x # is dangerous as it can expose secrets - use strategically

# Exit on error and pipe failures
set -eo pipefail

# Mask sensitive environment variables in logs
if [[ -n "${GH_TOKEN:-}" ]]; then
    echo "::add-mask::$GH_TOKEN"
fi

if [[ -n "${GPG_PASSPHRASE:-}" ]]; then
    echo "::add-mask::$GPG_PASSPHRASE"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/utils.sh"

secure_curl(){
    # Ensure debug is off during curl calls with tokens
    { set +x; } 2>/dev/null
    curl "$@"
    local ret=$?
    # Restore if it was on
    [[ -n "${ORIGINAL_DEBUG_MODE:-}" ]] && set -x
    return $ret
}

# NOTE: Always publish changelog before creating a new tag
publish_changelog() {
    log_info "===== Publish changelog ======"

    # Bring in the bump version commit from setup job BEFORE committing
    git fetch origin main
    git rebase origin/main # Local main now includes the bump version commit

    git add CHANGELOG.md
    commit_message="chore: update changelog for v$next_tag [no ci]"
    git commit -S -m "$commit_message"
    git log --show-signature

    # Use force-with-lease to prevent race conditions
    if ! git push --force-with-lease; then
        log_warning "Failed to push changelog, pulling latest changes"
        git pull --rebase origin main
        if ! git push; then
            handle_error 1 "Failed to push changelog after rebase"
        fi
    fi

    log_info "Changelog successfully published"
}

release_tag_to_github() {
    log_info "===== Create a new Github tag ======"

    # Create a signed and annotated git tag
    git tag -s -a "v$next_tag" -m "Release version $next_tag"

    # Verify signed tag
    # git tag -v "v$next_tag"

    message="The tag has been successfully published 🎉"

    # Push the tag to remote
    git push origin "v$next_tag" && log_info "$message"

    # Show the tag details
    git show "v$next_tag"

    log_info "Waiting for tag to be available on GitHub..."
    max_retries=10
    retry_count=0
    while [ $retry_count -lt $max_retries ]; do
        if git ls-remote --tags origin "v$next_tag" | grep -q "v$next_tag"; then
            log_info "Tag v$next_tag is now available on remote"
            break
        fi
        log_info "Waiting for tag propagation... (attempt $((retry_count + 1))/$max_retries)"
        sleep 2
        retry_count=$((retry_count + 1))
    done

    if [ $retry_count -ge $max_retries ]; then
        handle_error 1 "Tag v$next_tag did not become available on remote after $max_retries attempts"
    fi

    log_info "Tag v$next_tag pushed successfully to remote repository"
}

publish_artifacts(){
    log_info "===== Upload artifacts to a Github release ======"

    # Use colon as delimiter to support spaces in filenames
    IFS=':' read -r -a ARTIFACTS_PATHS <<< "$ARTIFACTS_PATHS_STR"

    if [[ -z "${ARTIFACTS_PATHS[*]:-}" ]]; then
        log_warning "No artifacts to upload"
        return 0
    fi

    RELEASE_ID=$1

    log_info "Uploading artifacts for the latest release"

    for artifact_path in "${ARTIFACTS_PATHS[@]}"; do
        # Trim whitespace
        artifact_path=$(echo "$artifact_path" | xargs)

        # Check if the artifact exists
        if [[ -f "$artifact_path" ]]; then
            log_info "Found artifact: $artifact_path"
        else
            handle_error 1 "Artifact not found: $artifact_path"
        fi

        # Extract filename from the path
        artifact_filename=$(basename "$artifact_path")
        # Get the MIME type dynamically
        mime_type=$(file -b --mime-type "$artifact_path")
        upload_url="https://uploads.github.com/repos/$USERNAME/$REPOSITORY_NAME/releases/$RELEASE_ID/assets?name=$artifact_filename"

        log_info "Uploading $artifact_path..."

        # Use separate files for body and status to avoid parsing issues
        local temp_body="/tmp/upload_response_body_$$"
        local temp_status="/tmp/upload_response_status_$$"

        HTTP_STATUS=$(curl -s -o "$temp_body" -w "%{http_code}" \
            -L \
            -X POST \
            -H "Authorization: Bearer $GH_TOKEN" \
            -H "Content-Type: $mime_type" \
            --data-binary @"$artifact_path" \
            "$upload_url"
            ) || {
                rm -f "$temp_body" "$temp_status"
                handle_error 1 "Failed to upload $artifact_filename"
            }

        HTTP_BODY=$(cat "$temp_body")
        rm -f "$temp_body"

        if [[ "$HTTP_STATUS" -ne 201 ]]; then
            log "${LOG_LEVEL_ERROR}" "Failed to upload: $artifact_filename (Status: $HTTP_STATUS)"
            log "${LOG_LEVEL_ERROR}" "Response: $(echo "$HTTP_BODY" | jq . 2>/dev/null || echo "$HTTP_BODY")"
            handle_error 1 "Failed to upload $artifact_filename"
        fi

        log_info "- $artifact_path file uploaded successfully."
    done

    log_info "All artifacts were uploaded successfully."
}

push_release_to_github() {
    log_info "===== Create a new Github release ======"

    # Check for existing release
    log_info "Checking for existing release..."
    local existing_release_response
    existing_release_response=$(secure_curl -s -w "\n%{http_code}" \
        -L \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer $GH_TOKEN" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/repos/""$USERNAME""/""$REPOSITORY_NAME""/releases/tags/v$next_tag" ) || true

    local existing_http_status
    existing_http_status=$(echo "$existing_release_response" | tail -n 1)

    if [[ "$existing_http_status" -eq 200 ]]; then
        local existing_release_id
        existing_release_id=$(echo "$existing_release_response" | head -n -1 | jq -r '.id')
        log_info "Release already exists with ID: $existing_release_id. Reusing existing release."
        RELEASE_ID="$existing_release_id"
        publish_artifacts "$RELEASE_ID"
        return 0
    fi

    

    # TODO: Before publishing a release check if the git tag is published to github
    # First check if the remote tag is pushed and available in github
    # git ls-remote --tags origin
    if ! git ls-remote --tags origin "v$next_tag" | grep -q "v$next_tag"; then
        handle_error 1 "Tag v$next_tag not found on remote. Push the tag first."
    fi

    # https://www.lucavall.in/blog/how-to-create-a-release-with-multiple-artifacts-from-a-github-actions-workflow-using-the-matrix-strategy
    # https://chatgpt.com/share/7a299605-4d36-48c0-9b5f-edbf8f055d01

    log_info "Creating release for tag v$next_tag (pre-release: $is_pre_release)"

    local release_notes
    release_notes=$(build_latest_changelog)

    log_info "release_notes: $release_notes"

    echo "$release_notes" > /tmp/release_notes_raw_$$
    escaped_release_notes=$(jq -Rs '.' /tmp/release_notes_raw_$$)
    rm -f /tmp/release_notes_raw_$$
    read -r -d '' JSON_PAYLOAD <<EOF || true
{
  "tag_name": "v$next_tag",
  "target_commitish": "main",
  "name": "v$next_tag",
  "body": $escaped_release_notes,
  "draft": false,
  "prerelease": $is_pre_release,
  "generate_release_notes": false
}
EOF

    # Create a new release
    local temp_body="/tmp/release_response_body_$$"
    HTTP_STATUS=$(
        curl -s -o "$temp_body" -w "%{http_code}" \
            -L \
            -X POST \
            -H "Accept: application/vnd.github+json" \
            -H "Authorization: Bearer $GH_TOKEN" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            https://api.github.com/repos/"$USERNAME"/"$REPOSITORY_NAME"/releases \
            -d "$JSON_PAYLOAD"
    ) || {
        rm -f "$temp_body"
        handle_error 1 "Failed to make an API request to GitHub"
    }

    HTTP_BODY=$(cat "$temp_body")
    rm -f "$temp_body"

    if [[ "$HTTP_STATUS" -ne 201 ]]; then
        log "${LOG_LEVEL_ERROR}" "Failed to create a new release in GitHub, HTTP status $HTTP_STATUS"
        echo "$HTTP_BODY" | jq '.message, .errors' 2>/dev/null || echo "$HTTP_BODY"
        handle_error 1 "Failed to create release"
    fi

    RELEASE_ID=$(echo "$HTTP_BODY" | jq -r '.id')
    if [[ -z "$RELEASE_ID" || "$RELEASE_ID" == "null" ]]; then
        handle_error 1 "ERROR: Release ID missing in response"
    fi

    log_info "Release created with ID: $RELEASE_ID"
    publish_artifacts "$RELEASE_ID"

    # Then check the response status code is 201 (created) to make sure the release is published in github
    # And also print the release info and maybe export it to a service using jq command and curl
    # and display a message to confirm that the release is published to github
    # like
    log_info "Release published successfully! 🎉"
}

# Main execution - only proceed if we have a next_tag
if [[ -z "${next_tag:-}" ]]; then
    log_warning "No next_tag provided. Nothing to publish."
    exit 0
fi

# Temporary disable debug output for sensitive operations
{ set +x; } 2>/dev/null

setup_git
publish_changelog
release_tag_to_github
push_release_to_github
