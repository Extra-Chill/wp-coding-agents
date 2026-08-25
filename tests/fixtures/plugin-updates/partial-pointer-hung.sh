#!/bin/bash
set -eu
plugin_dir="$1"
rm -f "$plugin_dir/.wp-coding-agents-release-current"
ln -s .wp-coding-agents-releases/new "$plugin_dir/.wp-coding-agents-release-current"
exec "$(dirname "$0")/hung.sh"
