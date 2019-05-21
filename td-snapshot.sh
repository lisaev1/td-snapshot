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
declare -r MAX_LEV=2

# Number of cycles to keep. E.g. for a daily backup scheme with CYCLE_LENGTH=7,
# this is the number of weeks worth of backups.
declare -r MAX_CYCLES=8

# NFS source for the backup storage
declare -r STORAGE_NFS="taupo.colorado.edu:/export/backup"

# -----------------------------------------------------------------------------
# Global constants
# -----------------------------------------------------------------------------

# Frequently used commands
declare -r xDUMP="$(type -pf dump)" xRM="/usr/bin/rm" xTEE="$(type -pf tee)" \
	xBTRFS="$(type -pf btrfs)" xMKDIR="$(type -pf mkdir)" \
	xMOUNT="$(type -pf mount)" xUMOUNT="$(type -pf umount)" \
	xREALPATH="$(type -pf realpath)" xSHA="$(type -pf sha256sum)" \
	xCP="$(type -pf cp)"

# Common mount-options
declare -r MOUNTOPTS="noexec,nosuid,nodev"

# Meta data directory
declare -r METADATA_DIR="/var/lib/td-backup"

# Info about mounted filesystems
# See "filesystems/proc.txt" in kernel docs for the format spec
declare -r MOUNTINFO="/proc/self/mountinfo"

# Short hostname of the machine
declare -r HOST="${HOSTNAME%%.*}"

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
	local -r snap_dir="_$(< /etc/machine-id)_backup_snapshots"

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
		_tee $xRM -v -- "$loop_img"

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
_initial_metadata_setup() {
	local fs x

	echo -E "+++ Creating metadata directory \"$METADATA_DIR\"..."
	# Create the "$METADATA_DIR" if not present already. On a btrfs
	# filesystem, we create a subvolume. Otherwise, a normal dir.
	if [[ ! -d "$METADATA_DIR" ]]; then 
		IFS="#" read -r fs x <<< \
			"$(_mnt2info "$(_closest_mountpoint /var/lib)")"

		if [[ "$fs" == "btrfs" ]]; then
			_tee $xBTRFS subvolume create "$METADATA_DIR"
		else
			_tee $xMKDIR -v "$METADATA_DIR"
		fi
	fi

	echo -E "--- initial setup done."
	return 0
}

#
# Determine state of the backup routine by reading "${METADATA_DIR}/state" if
# present. The state file has a space/tab-separated (dump-like) format:
# <ID> <tar/dump backend> <level> <UTC timestamp> <sha256sum of backup>
# <filename of the backup archive>
# For example:
# 2312f5635ef572c t 0 1543961163 <sha256sum> <fn>
# 2312f5635ef572c t 1 1543981163 <sha256sum> <fn>
# 2312f5635ef572c t 2 1543981180 <sha256sum> <fn>
# ...
# Clearly, the backend shouldn't change within a cycle, but it can be different
# for different cycles.
#
# Output: A set of strings separated by "#":
#	id = backup ID (either generated or read from the state file);
#	lev = level of the backup to continue with (special value -1 means that
#		a new cycle will start at level 0);
#	b = "tar" or "dump" backend used to take prev snapshot.
_read_state() {
	local id x b
	local -i lev n
	local -a a

	echo -E "+++ Parsing the state file at \"${STATE_FILE}\"..." 1>&2
	if [[ -f "$STATE_FILE" ]]; then
		n=0
		while read -ra a; do
			(( ++n ))
			read -r id b lev x <<< "${a[@]:0:4}"
		done < "$STATE_FILE"
		if [[ "$b" == "t" ]]; then
			b="tar"
		else
			b="dump"
		fi

		x="$(/usr/bin/date -d "@$x")"
		{
		 echo -E "... Current cycle ID is \"${id}\". The last backup at"
		 echo -E "... level $lev was taken on ${x} using ${b}."
	 	} 1>&2

		if (( n >= CYCLE_LENGTH )); then
			# We need to start a new cycle (with a new ID). The
			# special value lev = -1 indicates rotation of backups.
			# We also unset the backend variable to cover cases
			# when a user wants to switch backend in the new cycle.
			id="$(_rnd_alnum 15)"
			(( lev = -1 ))
			b=""

			echo -E "... Present cycle ended, starting a new one" 1>&2
		elif (( lev >= MAX_LEV )); then
			# We reached the max level and return back to level 1.
			# The ID is the same as the last backup.
			lev=1

			echo -E "... Max level reached, proceeding with lev 1" 1>&2
		else
			# Otherwise, just increment the last level value,
			# keeping the same ID.
			(( ++lev ))

			echo -E "... Continuing cycle with lev ${lev}" 1>&2
		fi
	else
		# If the state file doesn't exist, we start fresh (lev is set
		# to -1 to indicate rotation of backups that may exist, because
		# such situation would be common when an OS is reinstalled and
		# state files are lost but backups are present).
		id="$(_rnd_alnum 15)"
		(( lev = -1 ))

		echo -E "... State file not found. Starting a new cycle with ID = $id ." 1>&2
	fi
	echo -E "--- Finished reading state file." 1>&2

	echo -nE "${id}#${lev}#$b"
}

#
# Rotate backups on the server. The backup directory structure (starting from
# the storage mountpoint):
# /storage
# |
# |-- host1/
# |   |-- backup_name_1/
# |   |   |-- 0/
# |   |   |-- 1/
# |   |   ...
# |   |   `-- MAX_CYCLES/
# |   |-- backup_name_2/
# |   ...
# |-- host2/
# ...
#
_rotate_backups() {
	local d x
	local -i i

	echo -E "+++ Rotating backups..."

	d="${STORAGE_DIR}/$MAX_CYCLES"
	if [[ -d "$d" ]]; then
		echo -E "... Removing backup with number $MAX_CYCLES (= max)"
		_tee $xRM -vr -- "$d"
	fi

	for (( i = MAX_CYCLES - 1; i >= 0; --i )); do
		x="${STORAGE_DIR}/$i"
		[[ -d "$x" ]] && \
		      _tee /usr/bin/mv -v -- "$x" "${STORAGE_DIR}/$(( i + 1 ))"
	done
	_tee $xMKDIR -v "${STORAGE_DIR}/0"

	echo -E "--- Backup rotation done."
}

#
# Clean up the metadata directory
#
_metadata_cleanup() {
	local f

	# Purge old snapshot files
	for f in "${METADATA_DIR}/"*; do
		[[ (! -f "$f") || (! "$f" =~ -db-) ]] && continue
		[[ ("$f" =~ tar-db-.*-${ID}\.[0-9][0-9]*$) || \
			("$f" =~ dump-db-.*-${ID}$) ]] || _tee $xRM -v -- "$f"
	done

	return 0
}

#
# Incremental backup function using TAR/DUMP
#
# Input: $1 = level of this backup
#	$2 = path to compress ($rel_path)
# Output: a shasum-formatted string:
#	"sha256sum  backup_file_name"
_tar_backup() {
	local lev="$1" path="$2" d cs x

	(( lev )) && _tee $xCP -v -- \
		"${SNAPSHOT_FILE%.*}.$(( lev - 1 ))" "$SNAPSHOT_FILE"

	d="$(date -d "@$UTC_TS" "+%Y%m%d")"
	read -r cs x < <(/usr/bin/tar --xattrs -jpc \
	      --listed-incremental="$SNAPSHOT_FILE" -f - -C "$path" . | \
	      $xTEE "${STORAGE_DIR}/0/${SFX}.lev${lev}.${d}.tar.bz2" | $xSHA -)

	echo -nE "$cs ${SFX}.lev${lev}.${d}.tar.bz2"
}

_dump_backup() {
	local lev="$1" path="$2" d cs x

	d="$(date -d "@$UTC_TS" "+%Y%m%d")"
	read -r cs x < \
		<($xDUMP -D"$SNAPSHOT_FILE" -"$lev" -u -z6 -f - "$path" |\
	      $xTEE "${STORAGE_DIR}/0/${SFX}.lev${lev}.${d}.dump.gz" | $xSHA -)

	echo -nE "$cs ${SFX}.lev${lev}.${d}.dump.gz"
}

#
# Sanitize paths
#
# Avoid common cases when the dir name starts with "-", etc.
#
# Input: $1 = filename to sanitize
# Return: canonicalized filename with prepended full directory path
_sanitize_filename() {
        local f="$1"

	f="${f%/}"
	[[ "x${f#-}" == "x$f" ]] || f="./$f"
	[[ "x${f##*/}" == "x$f" ]] && f="./$f"
	echo -nE "$($xREALPATH "$f")"
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
	echo "Usage: td-snapshot.sh [-t tar|dump] -p <path> -n <name>"
	echo "-t <backend> : use tar(1) or dump(1) for incremental backups"
	echo "               if dump(1) is installed, use it for ext{2,3,4}"
	echo "               filesystems. Otherwise, use tar(1)."
	echo "-p <path>    : /path/to/data to backup"
	echo "-n <name>    : mnemonic name of the backup, e.g. \"home\". It is"
	echo "               used to name a dir with incremental backups."

	return 0
}

# -----------------------------------------------------------------------------
# Main program
# -----------------------------------------------------------------------------

# Declare veriables just to keep track of them
declare backend dir mnt_point filesystem device rel_path subvol_id snap_type \
	subvol_name ID SFX SRC_MNT STORAGE_MNT b_sf SNAPSHOT_FILE backup_name \
	STORAGE_DIR STATE_FILE
declare -i lev

# Handle the arguments
while getopts "t:p:n:h" arg; do
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
		n ) # name can't contain "/", so we replace them with "+"
		    backup_name="${OPTARG//\//+}"
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

# If no "-n" option was supplied, use "$dir" as the backup name (replacing "/"
# with "+")... 
if [[ -z "$backup_name" ]]; then
	backup_name="$($xREALPATH "$dir")"
	backup_name="${backup_name//\//+}"
fi

#
# General preparations
#

# Do some initial checks and setup the metadata directory
_initial_metadata_setup

# Set up more global constants:
#	SRC_MNT = mountpoint for the dir to be backed up
#	STORAGE_MNT = mountpoint for the backup storage
#	STORAGE_DIR = path to the actual backups (beneath $STORAGE_MNT)
#	STATE_FILE = state file for this $backup_name
b_sf="$(_rnd_alnum 15)"
readonly SRC_MNT="/dev/shm/backup-$b_sf" \
	STORAGE_MNT="/dev/shm/storage-$b_sf"
readonly STORAGE_DIR="${STORAGE_MNT}/${HOST}/$backup_name" \
	STATE_FILE="${METADATA_DIR}/${backup_name}.state"

# Read the state file
IFS="#" read -r ID lev b_sf <<< "$(_read_state)"
readonly ID

# Clean up old snapshot files that won't be used
#_metadata_cleanup "$backup_name"

# Create the mountpoints and mount the storage
_tee $xMKDIR -v "$SRC_MNT" "$STORAGE_MNT"
_tee $xMOUNT -v -t nfs4 "$STORAGE_NFS" "$STORAGE_MNT"

#
# Backup logic
#

# If the storage is fresh and we don't have the proper dir tree, we create the
# directory for the current cycle. Otherwise, we check if "$lev" == -1 and
# unconditionally rotate backups if yes.
if [[ ! -d "${STORAGE_DIR}/0" ]]; then
	if [[ -f "$STATE_FILE" ]]; then
		echo -E "!!! Warning !!!"
		echo -E "State file exists, but not the backup directory tree."
		echo -E "Assuming that previous backups are lost. Reverting to"
		echo -E "level 0 dump and removing state file."
		_tee $xRM -v -- "$STATE_FILE"
		b_sf=""
	fi
	_tee $xMKDIR -vp "${STORAGE_DIR}/0"
	lev=0
else
	# Level -1 occurs if there were no state file (fresh start) or a new
	# cycle started. In both cases, we set lev to 0 and remove state file.
	if (( lev == -1 )); then
		_rotate_backups
		[[ -f "$STATE_FILE" ]] && _tee $xRM -v -- "$STATE_FILE"
		lev=0
	fi
fi

#
# Snapshotting logic
#

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

# Check that btrfs-progs is installed
if [[ (-z "$xBTRFS") && ("$snap_type" == "btrfs") ]]; then
	echo -E "Can't use btrfs snapshots because \"btrfs-progs\" is not installed!"
	exit 1
fi

# Set up more global constants:
#	UTC_TS = Timestamp of this backup
# 	SFX = common unique suffix for dir names
readonly UTC_TS="$(/usr/bin/date "+%s")"
readonly SFX="${UTC_TS}-$ID"

# Print status
echo -E "Timestamp / ID: $UTC_TS / $ID"
echo -E "Host: $HOST"
echo -E "Backup target: \"${dir}\""
echo -E "Backup name: \"${backup_name}\""
echo -E "Level: $lev"
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

#
# Decide whether we want to use tar or dump
#
# If the previous backup used a particular backend (stored in "$b_sf"), then we
# ignore the backend specified via the "-t" cmdline switch. If "$b_sf" is null,
# we take the cmdline argument or set a default value for "$backend".
# We use dump only when (1) the script is run against a mountpoint, (2) the
# filesystem is ext2/3/4, and (3) dump is installed. If these conditions are
# met, dump is the default backend. Otherwise, we use tar.
if [[ -z "$b_sf" ]]; then
	if [[ ("$($xREALPATH "$rel_path")" == "$SRC_MNT") && \
		("$filesystem" =~ ^ext[2-4]$) && (-n "$xDUMP") ]]; then
		: "${backend:="dump"}"
	else
		backend="tar"
	fi
else
	backend="$b_sf"
fi
echo ""
echo -E "Using the $backend backend..."

#
# Checks w.r.t. tar or dump incremental backup snapshot files
#
# When (( lev != 0 )), we need to check if the tar or dump states used in
# building an incremental snapshot are present
if (( lev > 0 )); then
	echo ""
	echo -E "Checking presence of the previous $backend snapshot file..."

	b_sf="${METADATA_DIR}/${backend}-db-${backup_name}-$ID"
	[[ "$backend" == "tar" ]] && b_sf="${b_sf}.$(( lev - 1 ))"
	if [[ ! -f "$b_sf" ]]; then
		echo -E "!!! Warning !!!"
		echo -E "Level is ${lev}, but no lev $(( lev - 1 )) snapshot
info found! Something went wrong..."
		echo -E "Resetting to level 0 and purging the state file."
		_tee $xRM -v -- "$STATE_FILE"
		lev=0
	fi
fi

# Specify the tar or dump snapshot filename (for dump, aka dumpdates) 
SNAPSHOT_FILE="${METADATA_DIR}/${backend}-db-${backup_name}-$ID"
if [[ "$backend" == "tar" ]]; then
	SNAPSHOT_FILE="${SNAPSHOT_FILE}.$lev"
	if [[ -f "$SNAPSHOT_FILE" ]]; then
		echo -E "!!! Warning !!!"
		echo -E "Found stale lev $lev tar snapshot file \"${SNAPSHOT_FILE}\", removing..."
		_tee $xRM -v -- "$SNAPSHOT_FILE"
	fi
fi
readonly SNAPSHOT_FILE

# Do backup and update the state file with the new record
echo -E "Starting ${backend^^} level $lev snapshot..."
echo -E \
"$ID ${backend:0:1} $lev $UTC_TS $("_${backend}_backup" "$lev" "$rel_path")">>\
"$STATE_FILE"
echo -E "${backend^^} snapshot ready!"

# Cleanup the snapshots, umount storage and delete mountpoints
echo -E "!!! Cleanup !!!"
echo ""

"_${snap_type}_snapshot" "destroy" "$device" "$subvol_id"

echo ""
echo -E "Saving and cleaning up metadata..."
_tee $xCP -v -- "$STATE_FILE" "$STORAGE_DIR/0/"
if (( lev == MAX_LEV )); then
	_tee $xRM -v -- "$SNAPSHOT_FILE"
else
	_tee $xCP -v -- "$SNAPSHOT_FILE" "$STORAGE_DIR/0/"
fi

echo ""
echo -E "Unmounting storage..."
_tee $xUMOUNT -v "$STORAGE_MNT"

echo ""
echo -E "Removing mountpoints..."
_tee /usr/bin/rmdir -v "$SRC_MNT" "$STORAGE_MNT"
