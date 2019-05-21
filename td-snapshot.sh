#!/bin/bash

export LC_ALL=C
set -o errexit
#set -o xtrace

# -----------------------------------------------------------------------------
# Global constants
# -----------------------------------------------------------------------------

# Quasi-random salt
declare -r SALT="$(< /etc/machine-id)"

# Frequently used commands
declare -r xTAR="$(type -pf tar)" \
	xDUMP="$(type -pf dump)" \
	xBTRFS="$(type -pf btrfs)" \
	xSTAT="$(type -pf stat)" \
	xMKDIR="$(type -pf mkdir)" \
	xMOUNT="$(type -pf mount)" \
	xUMOUNT="$(type -pf umount)"

# Common mount-options
declare -r MOUNTOPTS="noexec,nosuid,nodev"

# Debug: 0 - silent; > 0 - be verbose
declare -r DEBUG=1

# Unique ID and timestamp of this backup
declare -r ID="$(/usr/bin/cat /dev/urandom | /usr/bin/tr -cd '[:alnum:]' | /usr/bin/head -c 10)" \
	UTC_TS="$(/usr/bin/date '+%s')" \
	SFX="${utc_ts}-$id"

# Mountpoint for the dir to be backed up
declare -r SRC_MNT="/dev/shm/backup-$SFX"

# Meta data directory
declare -r METADATA_DIR="/var/lib/backup"

# Info about mounted filesystems
# See "filesystems/proc.txt" in kernel docs for the format spec
declare -r MOUNTINFO="/proc/self/mountinfo"

# -----------------------------------------------------------------------------
# Functions
# -----------------------------------------------------------------------------

# Scan /proc/self/mountinfo for attributes of the FS mounted at a given
# mountpoint
#
# Input: $1 = mountpoint
# Return: a set of strings separated by "#":
#	fs = filesystem type (e.g. ext3)
#	dev = device (e.g. /dev/sda1)
# 	rel_path = root of the mount within the filesystem (for simple mounts
# 	           it is "/", but for bind-mounts can be /any/dir)
# 	s = parent subvolume ID of a dir in $1 if fs = btrfs or 0 otherwise
_mnt2info() {
	local mnt="$1" s fs
	local -a a
	local -i i

	# for other attributes. Only one entry must
	# match the desired FS, so we break the while loop after we find it.
	while read -ra a; do
		[[ "${a[4]}" == "$mnt" ]] && break
	done < "$MOUNTINFO"

	# "-" can be either 7th or 8th field (bash arrays are 0-based)
	for i in 6 7; do
		[[ "${a[i]}" == "-" ]] && break
	done
	fs="${a[i + 1]}"

	# For btrfs, we extract the subvolume ID (or set it to 0 otherwise).
	if [[ "$fs" == "btrfs" ]]; then
		s="${a[-1]#*,subvolid=}"
		s="${s%,*}"
	else
		s="0"
	fi

	echo -nE "${fs}#${a[i + 2]}#${a[3]}#${s}"
}

#
# Determine subvol ID by its name (if $1 = id), or vice versa (if $1 = name) of
# a BTRFS subvolume -- works only on a mounted FS!
#
# Input: $1 = what to return (id/name)
#	$2 = known characteristic (id/name)
#	$3 = FS mountpoint
# Return: name of the subvolume
_btrfs_idname() {
	local t="$1" c="$2" m="$3"
	local -i i1 i2
	local -a a

	case "$t" in
		name | n ) # We want to find subvol name by its ID
		       i1=1
		       i2=-1
		;;
		id | i | ID ) # We want to find subvol ID by its name
		     i1=-1
		     i2=1
		;;
		* ) # For anythin else we quit
		    echo -E "_btrfs_idname(): 1st arg must be either \"id\" or \"name\""
		    exit 1
	esac

	while read -ra a; do
		[[ "${a[$i1]##*/}" == "$c" ]] && break
	done < <($xBTRFS subvolume list "$m")

	echo -nE "${a[$i2]}"
}

#
# Make & mount ro snapshot when the backup target is on btrfs
#
# Input: $1 = device
# 	$2 = subvolid
# Return: ID of the snapshot
_btrfs_snapshot() {
	local dev="$1" subvolid="$2" name
	local -r snap_dir="_${SALT}_backup_snapshots"

	# Mount the entire BTRFS device "$dev"
	$xMOUNT -o "${MOUNTOPTS},subvolid=5" "$dev" "$SRC_MNT"

	# For our subvolid (!= 5), find the corresponding name. The
	# subvolid = 5 does not show up in the list and "$name" is unset.
	[[ "$subvolid" != "5" ]] && \
		name="$(_btrfs_idname "name" "$subvolid" "$SRC_MNT")"

	# If necessary, make a subvolume for future snapshots
	[[ ! -d "${SRC_MNT}/$snap_dir" ]] && \
		$xBTRFS subvolume create "${SRC_MNT}/$snap_dir"

	# Snapshot our parent subvolume and mount it ro
	subvolid="backup-snapshot-${name:-"id5"}-$SFX"
	$xBTRFS subvolume snapshot -r "${SRC_MNT}/$name" \
		"${SRC_MNT}/${snap_dir}/$subvolid"

	# Mount the snapshot (by its ID)
	subvolid="$(_btrfs_idname "id" "$subvolid" "$SRC_MNT")"
	$xUMOUNT "$SRC_MNT"
	$xMOUNT -o "ro,${MOUNTOPTS},subvolid=$subvolid" "$dev" "$SRC_MNT"

	echo -nE "$subvolid"
}

#
# LVM snapshots.
# Contrary to btrfs, LVM needs an explicit space allocation for snapshots.
# Therefore, we will:
# - create a 500M loop device located in RAM (/dev/shm);
# - turn it into a PV, and extend the proper VG over it;
# - make a snapshot of the proper LV.
#
# Input: 
_lvm_snapshot() {
}

#
# Initial setup (if called for the first time)
#
_initial_setup() {
	local fs x

	# Create the "$METADATA_DIR" if not present already. On a btrfs
	# filesystem, we create a subvolume. Otherwise, a normal dir.
	if [[ ! -d "$METADATA_DIR" ]]; then 
		IFS="#" read -r fs x <<< \
			"$(_mnt2info "$($xSTAT --printf=%m /var/lib)")"

		if [[ "$fs" == "btrfs" ]]; then
			$xBTRFS subvolume create "$METADATA_DIR"
		else
			$xMKDIR "$METADATA_DIR"
		fi
	fi

	# Create the protected mountpoint for snapshots or ro mounts
	$xMKDIR "$SRC_MNT"

	return 0
}

#
# Sanitize paths
#
# Avoid common cases when the dir name starts with "-", etc.
# Input: $1 = filename to sanitize
# Return: filename with prepended "./"
_sanitize_filename() {
        local f="$1"

	f="${f%/}"
        [[ x"${f#-}" == x"$f" ]] || f="./$f"
        [[ x"${f##*/}" == x"$f" ]] && f="./$f"

        echo -nE "$f"
}

#
# Check if the directory to be backed up actually exists
#
# Input: $1 = filename to check
_check_dir() {
        if [[ ! -d "$1" ]]; then
                echo -E "Can not access directory \"${1}\"."
		echo "Does it exist and have proper permissions?"
                return 1
        fi
}

_usage() {
	echo ""
	echo "Usage: td-snapshot.sh [-t tar|dump] -p <path>"
	echo "-t <backend> : use tar(1) or dump(1) for incremental backups"
	echo "               if dump(1) is installed, use it for ext{2,3,4}"
	echo "               filesystems. Otherwise, use tar(1)."
	echo "-p <path>    : /path/to/data to backup"

	return 0
}

# -----------------------------------------------------------------------------
# Main program
# -----------------------------------------------------------------------------

# This is just to keep track of variables
declare backend dir mnt_point filesystem device rel_path subvol_id snap_type \
	subvol_name

# Handle the arguments
while getopts "t:p:h" arg; do
	case $arg in
		t ) # quit if not "tar" or "dump"
		    if [[ "$OPTARG"  == "tar" || "$OPTARG" == "dump" ]]; then
			    backend="$OPTARG"
		    else
			    echo -E "Invalid backend \"${OPTARG}\""
			    _usage
			    exit 1
		    fi
		;;
		p ) # sanitize the path
		    dir="$(_sanitize_filename "$OPTARG")"
		    _check_dir "$dir" || exit 1
		;;
		h | * ) # print usage and exit
			_usage
			exit 0
		;;
	esac

done

# Abort if no "-p" option was provided
if [[ -z "$dir" ]]; then
	echo -E "No path is provided... aborting"
	_usage
	exit 1
fi

# Do some initial checks and setup
#_initial_setup

# Determine attributes of "$dir"
mnt_point="$($xSTAT --printf=%m "$dir")"
IFS="#" read -r filesystem device rel_path subvol_id <<< \
	"$(_mnt2info "$mnt_point")"

# Next we proceed as follows:
# * if "$dir" is on a btrfs subvolume (or is a mountpoint for a subvolume,
#   remember that the root btrfs FS is also a subvolume with ID = 5), we will
#   use btrfs native snapshotting capabilities;
# * if "$dir" is not on btrfs, we check whether it belongs to (or is a
#   mountpoint for) a logical volume and, if yes, use LVM snapshots. Otherwise
#   (if we have a basic device), no snapshotting will be done.
# Note: if lvs(8) is not found, then LVM is not installed and we can't do
# snapshots. Therefore, we treat this situation as if the device is raw.
if [[ "$filesystem" == "btrfs" ]]; then
	snap_type="btrfs"
elif /usr/bin/lvs "$device" &> /dev/null; then
	snap_type="lvm"
else
	snap_type="none"
fi

# Print status
if (( DEBUG )); then
	echo -E "Timestamp: $UTC_TS"
	echo -E "ID: $ID"
	echo -E "Backup target: \"${dir}\""
	[[ "$subvol_id" != "0" ]] && echo -E "Parent subvolume ID: $subvol_id"
	echo -E "Closest mountpoint: \"${mnt_point}\""
	echo -E "Path within parent device: \"${rel_path}\""
	echo -E "Device: $device"
	echo -E "Snapshots: $snap_type"
fi
exit 0

# Create a shapshot
subvol_name="$("_${snap_type}_snapshot" "$device" "$subvol_id")"
if [[ -n "$subvol_name" ]]; then
	rel_path="${SRC_MNT}/${rel_path#/${subvol_name}/}"
else
	rel_path="${SRC_MNT}/${rel_path#/}"
fi
rel_path="${rel_path}/${dir#${mnt_point}/}"
