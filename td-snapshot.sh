#!/bin/bash

export LC_ALL=C
set -o errexit
#set -o xtrace

# -----------------------------------------------------------------------------
# Backup parameters
# -----------------------------------------------------------------------------

# Length of a cycle. For a traditional case when we do lev_0 backup on Monday
# morning and lev_n (n >= 1) on each following day of the week, CYCLE_LENGTH=7.
declare -r CYCLE_LENGTH=10

# Max level to achieve. This number must be commensurate with CYCLE_LENGTH and
# an implicit timing of the backups. For example, within a daily backup
# routine, one can not have MAX_LEV >= CYCLE_LENGTH. Once MAX_LEV is reached,
# we restart from level 1.
declare -r MAX_LEV=1

# Number of cycles to keep. E.g. for a daily backup scheme with CYCLE_LENGTH=7,
# this is the number of weeks worth of backups.
declare -r MAX_CYCLES=8

# -----------------------------------------------------------------------------
# Global constants
# -----------------------------------------------------------------------------

# Quasi-random salt
declare -r SALT="$(< /etc/machine-id)"

# Frequently used commands... ALl systems are expected to have tar, mount,
# umount and mkdir, but not necessarily btrfs, dump or lvs. If they are not
# present, we replace them with /bin/false to fail subsequent checks.
declare xTAR="$(type -pf tar)" xDUMP="$(type -pf dump)" \
	xBTRFS="$(type -pf btrfs)" \
	xMOUNT="$(type -pf mount)" xUMOUNT="$(type -pf umount)" \
	xMKDIR="$(type -pf mkdir)"
: "${xDUMP:=/bin/false}"
: "${xBTRFS:=/bin/false}"
readonly xTAR xDUMP xBTRFS xMOUNT xUMOUNT xMKDIR

# Common mount-options
declare -r MOUNTOPTS="noexec,nosuid,nodev"

# Meta data directory
declare -r METADATA_DIR="/var/lib/td-backup"
declare -r STATE_FILE="${METADATA_DIR}/state"

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
# Input: $1 = mode of operation (create/destroy)
#	$2 = device
# 	$3 = subvolid
# Return: ID of the snapshot
_btrfs_snapshot() {
	local mode="$1" dev="$2" subvolid="$3" snap_name name snap_id
	local -r snap_dir="_${SALT}_backup_snapshots"

	if [[ "x$mode" == "xcreate" ]]; then
		# We want to create the snapshot
		echo -E "+++ Making and mounting btrfs snapshot..." 1>&2
	else
		# We are done and want to destroy the snapshot. Remember that
		# after calling "_btrfs_snapshot create", "$SRC_MNT" is a
		# mountpoint for the *snapshot*, so we umount it first, then
		# mount the full device and delete the snapshot.
		echo -E "+++ Dismantling btrfs snapshot..."
		_tee $xUMOUNT -v "$SRC_MNT"
	fi

	# Mount the entire BTRFS device "$dev"
	_tee $xMOUNT -v -o "${MOUNTOPTS},subvolid=5" "$dev" "$SRC_MNT"

	# For our subvolid (!= 5), find the corresponding name. The
	# subvolid = 5 does not show up in the list and "$name" is unset.
	[[ "$subvolid" != "5" ]] && \
		name="$(_btrfs_idname "name" "$subvolid" "$SRC_MNT")"
	snap_name="backup-snapshot-${name:-"id5"}-$SFX"

	if [[ "x$mode" == "xdestroy" ]]; then
		_tee $xBTRFS subvolume delete -C \
			"${SRC_MNT}/${snap_dir}/$snap_name"
		_tee $xUMOUNT -v "$SRC_MNT"
		echo -E "--- btrfs snapshot \"${snap_name}\" destroyed"

		return 0
	fi

	# If necessary, make a subvolume for future snapshots
	[[ ! -d "${SRC_MNT}/$snap_dir" ]] && \
		_tee $xBTRFS subvolume create "${SRC_MNT}/$snap_dir"

	# Snapshot our parent subvolume and mount it ro
	_tee $xBTRFS subvolume snapshot -r "${SRC_MNT}/$name" \
		"${SRC_MNT}/${snap_dir}/$snap_name"
	snap_id="$(_btrfs_idname "id" "$snap_name" "$SRC_MNT")"

	_tee $xUMOUNT -v "$SRC_MNT"
	_tee $xMOUNT -v -o "ro,${MOUNTOPTS},subvolid=$snap_id" "$dev" \
		"$SRC_MNT"

	echo -E "--- snapshot ID $snap_id mounted at $SRC_MNT" 1>&2
	echo -nE "$name"
}

#
# LVM snapshots.
# Contrary to btrfs, LVM needs an explicit space allocation for snapshots.
# Therefore, we will:
# - create a 500M loop device located in RAM (/dev/shm);
# - turn it into a PV, and extend the proper VG over it;
# - make a snapshot of the proper LV.
#
# Input: $1 = mode of operation (create/destroy)
#	$2 = device
_lvm_snapshot() {
	local mode="$1" dev="$2" lv vg loop_img loop_dev snap_name x
	local -r xLOSETUP="$(type -pf losetup)"

	# Get LV and VG names for the device "$dev"
	read -r lv vg < \
		<(/usr/sbin/lvs --noheadings -o lvname,vgname "$dev")
	snap_name="backup-snapshot-${vg}_${lv}-$SFX"

	# Create the auxiliary loop dev
	loop_img="/dev/shm/${snap_name}.img"
	if [[ -f "$loop_img" ]]; then
		IFS=":" read -r loop_dev x < \
			<($xLOSETUP -j "$loop_img")
	else
		_tee /usr/bin/dd if=/dev/zero of="$loop_img" bs=500M count=1
		loop_dev="$($xLOSETUP --show -f "$loop_img")"
	fi

	# We are done and want to destroy the snapshot
	if [[ "x$mode" == "xdestroy" ]]; then
		echo -E "+++ Dismantling LVM snapshot \"${vg}/${snap_name}\"..."
		_tee $xUMOUNT -v "$SRC_MNT"
		_tee /usr/sbin/lvremove -v -y "${vg}/$snap_name"
		_tee /usr/sbin/vgreduce -v -y "$vg" "$loop_dev"
		_tee /usr/sbin/pvremove -v -y "$loop_dev"
		_tee $xLOSETUP -d "$loop_dev"
		_tee /usr/bin/rm -vf "$loop_img"

		echo -E "--- LVM snapshot destroyed"

		return 0
	fi

	# If we are here, we want to create the snapshot
	echo -E "+++ Making and mounting LVM snapshot..." 1>&2

	# Initialize "$loop_dev" as a PV and include it into "$vg"
	_tee /usr/sbin/pvcreate -v -y "$loop_dev"
	_tee /usr/sbin/vgextend -v -y "$vg" "$loop_dev"

	# Create and mount the snapshot
	_tee /usr/sbin/lvcreate -v -y -p r -l "100%PVS" -n "$snap_name" \
		-s "${vg}/$lv" "$loop_dev"
	_tee $xMOUNT -v -o "ro,${MOUNTOPTS}" "/dev/${vg}/$snap_name" "$SRC_MNT"

	echo -E "--- LVM snapshot \"${vg}/${snap_name}\" mounted at \"${SRC_MNT}\"" 1>&2
	return 0
}

#
# A trivial function to make a "snapshot" of the backup target when it resides
# neither on a btrfs filesystem or an LV. In this case, the snapshot is simply
# a ro mount of the original device.
#
# Input: $1 = mode of operation (create/destroy)
#	$2 = device
_none_snapshot() {
	local mode="$1" dev="$2"

	# We are done and want to umount the backup target
	if [[ "x$mode" == "xdestroy" ]]; then
		echo -E "+++ Dismantling the ro mount at \"${SRC_MNT}\"..."
		_tee $xUMOUNT -v "$SRC_MNT"
		echo -E "--- $SRC_MNT unmounted"
		return 0
	fi

	# If we are here, we want to ro mount the backup target
	echo -E "+++ Mounting ro the backup target..." 1>&2
	_tee $xMOUNT -v -o "ro,${MOUNTOPTS}" "$dev" "$SRC_MNT"
	echo -E "--- Backup target is mounted at \"${SRC_MNT}\"" 1>&2

	return 0
}

#
# Initial setup (if called for the first time)
#
_initial_setup() {
	local fs x

	echo -E "+++ Creating metadata directory \"$METADATA_DIR\" and the mountpoint for"
	echo -E "+++ backup source at \"$SRC_MNT\"..."
	# Create the "$METADATA_DIR" if not present already. On a btrfs
	# filesystem, we create a subvolume. Otherwise, a normal dir.
	if [[ ! -d "$METADATA_DIR" ]]; then 
		IFS="#" read -r fs x <<< \
			"$(_mnt2info "$(_closest_mountpoint /var/lib)")"

		if [[ "$fs" == "btrfs" ]]; then
			$xBTRFS subvolume create "$METADATA_DIR"
		else
			$xMKDIR -v "$METADATA_DIR"
		fi
	fi

	# Create the protected mountpoint for snapshots or ro mounts
	$xMKDIR -v "$SRC_MNT"

	echo -E "--- initial setup done."
	return 0
}

#
# Determine state of the backup routine by reading "${METADATA_DIR}/state" if
# present. The state file has a space/tab-separated (dump-like) format:
# <ID> <level> <UTC timestamp> <human-readable date>
# For example:
# 2312f5635ef572c 0 1543961163 Tue Dec  4 22:06:03 UTC 2018
# 2312f5635ef572c 1 1543981163 Wed Dec  5 03:39:23 UTC 2018
# 2312f5635ef572c 2 1543981180 Wed Dec  5 03:39:40 UTC 2018
# ...
#
# Output: A set of strings separated by "#":
#	id = backup ID (either generated or read from the state file);
#	lev = level of the backup to continue with (special value -1 means that
#		a new cycle will start at level 0).
_read_state() {
	local id x
	local -i lev n

	echo -E "+++ Parsing the state file at \"${STATE_FILE}\"..." 1>&2
	if [[ -f "$STATE_FILE" ]]; then
		n=0
		while read -r id lev x x; do
			(( ++n ))
		done < "$STATE_FILE"

		echo -E "     Current cycle ID is \"${id}\". The last backup at level $lev was taken on ${x}." 1>&2

		if (( n >= CYCLE_LENGTH )); then
			# We need to start a new cycle. The special value
			# lev = -1 indicates rotation of backups.
			id="$(_rnd_alnum 15)"
			(( lev = -1 ))

			echo -E "     Present cycle ended -- starting a new one." 1>&2
		elif (( lev >= MAX_LEV )); then
			# We reached the max level and return back to level 1.
			# The ID is the same as the last backup.
			lev=1

			echo -E "     Max level reached -- continuing the cycle with level 1" 1>&2
		else
			# Otherwise, just increment the last level value,
			# keeping the same ID.
			(( ++lev ))

			echo -E "     Continuing this cycle with level ${lev} ." 1>&2
		fi
	else
		# If the state file doesn't exist, we start fresh (lev is set
		# to -1 to indicate rotation of backups that may exist, because
		# such situation would be common when an OS is reinstalled and
		# state files are lost but backups are present).
		id="$(_rnd_alnum 15)"
		(( lev = -1 ))

		echo -E "     State file is missing. Starting a new cycle with ID = $id ." 1>&2
	fi
	echo -E "--- Finished reading state file." 1>&2

	echo -nE "${id}#${lev}"
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
	[[ "x${f#-}" == "x$f" ]] || f="./$f"
	[[ "x${f##*/}" == "x$f" ]] && f="./$f"
	echo -nE "$(/usr/bin/realpath "$f")"
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

#
# Find the closest mountpoint for a directory, emulating stat --printf=%m. The
# latter has an issue with btrfs subvolumes, as it returns the closest
# subvolume even if the actual mountpoint is higher up the tree.
#
# Input: $1 = directory
# Return: mountpoint path
_closest_mountpoint() {
	local fs="$1"

	while :; do
        	/usr/bin/mountpoint -q "$fs" && break

        	fs="${fs%/*}"
		if [[ -z "$fs" ]]; then
			fs="/"
			break
		fi
	done

	echo -nE "$fs"
}

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
	while (( l )); do
        	s="${s%[0-9a-f]}"
        	(( --l ))
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
} 1>&2

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

# Unique ID and timestamp of this backup
declare -r ID="$(_rnd_alnum 15)" \
	UTC_TS="$(/usr/bin/date '+%s')"
declare -r SFX="${UTC_TS}-$ID"

# Mountpoint for the dir to be backed up
declare -r SRC_MNT="/dev/shm/backup-$SFX"

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
_initial_setup

# Determine attributes of "$dir"
mnt_point="$(_closest_mountpoint "$dir")"
IFS="#" read -r filesystem device rel_path subvol_id <<< \
	"$(_mnt2info "$mnt_point")"

# Next we proceed as follows:
# * if "$dir" is on a btrfs subvolume (or is a mountpoint for a subvolume,
#   remember that the root btrfs FS is also a subvolume with ID = 5), we will
#   use btrfs native snapshotting capabilities;
# * if "$dir" is not on btrfs, we check whether it belongs to (or is a
#   mountpoint for) a logical volume and, if yes, use LVM snapshots. Otherwise
#   (if we have a basic device), no snapshotting will be done.
if [[ "$filesystem" == "btrfs" ]]; then
	snap_type="btrfs"
elif /usr/sbin/lvs "$device" &> /dev/null; then
	snap_type="lvm"
else
	snap_type="none"
fi

# Print status
echo -E "Timestamp: $UTC_TS"
echo -E "ID: $ID"
echo -E "Backup target: \"${dir}\""
[[ "$subvol_id" != "0" ]] && echo -E "Parent subvolume ID: $subvol_id"
echo -E "Closest mountpoint: \"${mnt_point}\""
echo -E "Path within parent device: \"${rel_path}\""
echo -E "Device: $device"
echo -E "Snapshots: $snap_type"
echo ""

# Create a shapshot
subvol_name="$("_${snap_type}_snapshot" "create" "$device" "$subvol_id")"
if [[ -n "$subvol_name" ]]; then
	rel_path="${SRC_MNT}/${rel_path#/${subvol_name}}"
else
	rel_path="${SRC_MNT}/${rel_path#/}"
fi
rel_path="${rel_path}/${dir#${mnt_point}}"
