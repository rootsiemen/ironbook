#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/vars.sh"

source "$SCRIPTS_DIR/lib/utility.sh"
source "$SCRIPTS_DIR/lib/help.sh"
source "$SCRIPTS_DIR/build/build.sh"
source "$SCRIPTS_DIR/build/package.sh"
source "$SCRIPTS_DIR/build/generate_changelog.sh"
source "$SCRIPTS_DIR/tools/get_codebase.sh"
source "$SCRIPTS_DIR/tools/get_tree.sh"
source "$SCRIPTS_DIR/release/sign.sh"
source "$SCRIPTS_DIR/lib/update.sh"
source "$SCRIPTS_DIR/release/update_version.sh"
source "$SCRIPTS_DIR/release/release.sh"

# ==============================================================================
# Main Command Router
# ==============================================================================

COMMAND="${1:-help}"

case "$COMMAND" in
    get-tree)
        cmd_get_tree
        ;;

    get-codebase)
        cmd_get_codebase
        ;;

    update-version)
        shift
        cmd_update_version "$@"
        ;;

    build)
        shift
        cmd_build "$@"
        ;;

    release)
        shift
        cmd_release "$@"
        ;;

    check-update)
        shift
        cmd_check_update "$@"
        ;;

    setup)
        shift
        source "$SCRIPTS_DIR/setup/setup.sh" "$@"
        ;;

    help|--help|-h)
        cmd_help
        ;;

    *)
        echo "❌ Unknown command: '$COMMAND'"
        echo ""
        cmd_help
        exit 1
        ;;
esac
