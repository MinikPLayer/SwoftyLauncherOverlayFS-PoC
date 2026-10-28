#!/bin/bash

# Replace a string with another string in a string variable
# Usage: replace "$SOURCE" "$MATCH" "$REPLACEMENT"
replace() {
  if [[ $# -ne 3 ]]; then
    echo "Usage: replace <string> <old> <new>" >&2
    return 2
  fi

  local str=$1 old=$2 new=$3

  if [[ -z $str ]]; then
    echo "replace: <string> must not be empty" >&2
    return 1
  fi
  if [[ -z $old ]]; then
    echo "replace: <old> must not be empty" >&2
    return 1
  fi

  printf '%s\n' "${str//"$old"/"$new"}"
}

# Original game directory is the PWD in which the game (so this script) was started in.
OG_GAME_DIR="$PWD"

# Overlay directory containing files created by the swofty launcher.
OVERLAY_DIR="/home/minik/.local/share/swofty-overlay-example"

# Temporary directory to mount the game. It's using a namespaced mount, so it's not necessary to check if it exists or not, as it's going to be overlayed anyway.
TARGET_DIR="/tmp/game"

# Create the target directory if it doesn't exists.
# WARNING! Here we should check if we're allowed to created this directory and choose another one if it fails.
# TODO (in the future): Create a tmpfs mount and pick a target directory in this new mount. Do not do this for the MVP.
mkdir -p "$TARGET_DIR"

# Mount OverlayFS with both directories used as lowerdir (so both are read-only).
# This is what we want, as we don't want for any program to write into our cache, while original writes (from Steam for example) still go into the original folder (under $OG_GAME_DIR).
mount -t overlay -o "lowerdir=$OVERLAY_DIR:$OG_GAME_DIR" none "$TARGET_DIR"

# Check into the target directory, so the PWD becomes valid for our future session
cd "$TARGET_DIR"

# Original launch parameters are passed as "$@". Swofty launcher gets it's launch parameters in a similar way, but parameters may be different - check before coding.
CMD_OG="$@"

# Replace the game directory with the temp (mounted) directory in the launch string.
# This is required, as without this it would launch the original exe.
CMD_NEW=$(replace "$CMD_OG" "$OG_GAME_DIR" "$TARGET_DIR")

# Run the game using the newly modified parameters.
eval $@
