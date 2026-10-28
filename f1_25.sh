#!/bin/bash

# Open a new namespace with mount privileges
# Run the run script inside
# Pass original parameters to this script.
unshare -Urm "f1_25_unshared.sh" "$@"
