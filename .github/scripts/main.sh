#!/usr/bin/env bash

# Enable strict mode
set -euo pipefail

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Entry point
main() {
    local command="${1:-}"

    case "$command" in
    "setup")
        # Run in a subshell to prevent variable leakage
        (
            # shellcheck disable=SC1091
            if ! source "$SCRIPT_DIR/setup.sh"; then
                echo "Error: Failed to source setup.sh" >&2
                exit 1
            fi
        ) || exit 1
        ;;
    "release")
        # Run in a subshell to prevent variable leakage
        (
            # shellcheck disable=SC1091
            if ! source "$SCRIPT_DIR/release.sh"; then
                echo "Error: Failed to source release.sh" >&2
                exit 1
            fi
        ) || exit 1
        ;;
    *)
        echo "Error: Invalid option '$command'. Valid options: setup, release"
        exit 1
        ;;
    esac
}

# Here we check that the number of arguments is greater than 0
if [[ $# -ge 1 ]]; then
    # Invoking main function
    main "$@"
    exit 0
else
    echo "Please provide the required arguments! (setup or release)"
    exit 1
fi

