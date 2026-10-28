#!/bin/bash

# Both f1_25.sh and f1_25_unshared.sh must be placed in the F1 25 game folder.
# Steam starts this script with the game folder as the working directory, which is later used as the original game directory.

# Open a new namespace with mount privileges
# Run the run script inside (looked up next to this script, so it doesn't need to be in PATH)
# Pass original parameters to this script.
unshare -Urm "$(dirname "$(readlink -f "$0")")/f1_25_unshared.sh" "$@"
