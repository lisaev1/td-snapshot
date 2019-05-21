#!/bin/bash

export LC_ALL=C
set -o errexit
#set -o xtrace

# -----------------------------------------------------------------------------
# Functions
# -----------------------------------------------------------------------------

#
# Generate a random lower-case alpha-numeric string of a given length.
#
# Input: $1 = length
# Return: random string
_rnd_alnum() {
        local -i l="$1"
        local s="$(printf "%x" $RANDOM)"

        (( l <= 0 )) && return 1

        while (( ${#s} < l )); do
                s="$(printf "%x" $RANDOM)$s"
        done

        l=$(( ${#s} - l ))
        while (( l-- )); do
                s="${s%[0-9a-f]}"
        done

        echo -nE "$s"
}

#
# A tee-like function to echo a command before executing it.
#
# Input: command
_tee() {
        echo ""
        echo -E "~~>  $@"
        "$@"
}

# -----------------------------------------------------------------------------
# Parameters
# -----------------------------------------------------------------------------

# Source and destination mountpoints
declare -r SRC_MNT="/export/backup" \
	DST_MNT="/dev/shm/backup-mirror-$(_rnd_alnum 15)"

# UUID of the mirror
declare -r UUID="bab9da0e-0ce1-47aa-a533-340e4bc5d5d5"

# -----------------------------------------------------------------------------
# Main program
# -----------------------------------------------------------------------------

# Make the destination mountpoint and mount the mirror
_tee /usr/bin/mkdir -v "$DST_MNT"
_tee /usr/bin/mount -v -o noexec,nosuid,nodev \
	"/dev/disk/by-uuid/$UUID" "$DST_MNT"

# Sync backup and its mirror
_tee /usr/bin/rsync -aAX --delete --exclude="lost+found" \
	"${SRC_MNT}/" "${DST_MNT}/"

# Clean up
/usr/bin/sync && sleep 15
_tee /usr/bin/umount -v "$DST_MNT"
_tee /usr/bin/rmdir -v "$DST_MNT"
