# A snapshot-capable backup utility that uses GNU tar(1) or dump(1)

## Table of contents
0. Credits
1. Dependencies and invocation
2. Overview and some motivation
3. Main features
4. License

## Credits

The inspiration for this little script comes from the [rsnapshot](https://rsnapshot.org/) program and an [article](http://www.mikerubel.org/computers/rsync_snapshots) by Mike Rubel.

## Dependencies and invocation

Most likely, you won't need to install any packages to make `td-snapshot.sh` run... but just in case these are external tools which we use (**bold** means mandatory dependencies): **bash >= 4**, **coreutils**, **tar**, **util-linux**, lvm2, btrfs-progs, dump.

You would typically call `td-snapshot.sh` from a cron job, e.g.
```
# crontab -l
45 1 * * * /bin/bash /usr/local/sbin/td-snapshot.sh -p /export/home -n home 2>&1 | /usr/bin/logger -p daemon.info -t backup
```

## Overview and some motivation

The "td-snapshot" tool atomically backs up a set of Linux machines to a centralized storage. While this is a standard task that faces any system administrator, it turned out quite difficult to find a tool that fits our requirements:

1. The backup solution should be easy to use, preferably "fire and forget".
2. It should be simple and not involve any complicated storage or configuration formats. Additionally, an administrator should be able to do a recovery only with standard system tools, like GNU `tar` or `mount`.
3. The program should be able to choose an incremental backup backend, based on the underlying filesystem, storage configuration and admin's preferences (in our group there was a strong preference to use ext4 on LVM and `dump`, but there are also some /home's on btrfs).
4. The dumps must be atomic.

Most of the tools, that we looked at checked only a subset of the above points, for example, [amanda](www.amanda.org) is great and was already used by our computing group, but is difficult (for us) to configure. [Borg](https://borgbackup.readthedocs.io/en/stable/) is also great, but has a complicated repository format. The best candidate which fitted our workflow almost perfectly was `rsnapshot`, but it uses `rsync` and our users tend to have **lots** of files, so we were afraid to run out of inodes on our backup server. But the nice feature of `rsnapshot` is its extensibility, specifically, it can be told to do LVM snapshots before calling `rsync`.

Ideally, the simplest course of action for us would have been to hack on `rsnapshot` and make it use `tar` or `dump` instead of `rsync`, but none of us knew perl well enough. In the end, we decided to make our own tool that we can stick into `cron` and get back to science :)

Finally, the name "td-snapshot" is a nod to `rsnapshot`, but `rsync` is replaced with Tar and Dump (TD).

## Main features of `td-snapshot`

So, what does `td-snapshot.sh` (td-s) actually do? This section gives a high-level answer to this question, for more details, please see the comments inside the script itself.

TD-S performs incremental backups of a directory to a specified NSF server, which is currently hard-coded in the script but can be trivially changed (we felt this is a one-time setup, like the backup strategy, and shouldn't be exposed through optional arguments). Very broadly, you can think of it as a bash wrapper for `dump`: The admin chooses backup schedule (when to do a level 0 dump, how many higher levels are within one cycle, etc.), source directory, name of the backup, and optionally the compression backend (`tar` or `dump`). The wrapper detects the storage configuration that corresponds to the source dir (the filesystem, whether it's on an LVM volume or btrfs subvolume), if possible, makes a snapshot using appropriate tools (lvm or btrfs snapshots), and dumps the filesystem according to the prescribed strategy. The rest of the script is plumbing to generate proper timestamps, checksums and verify that the backup went smoothly.

Of course, `dump` only works on ext[2-4], so to handle data on btrfs we use [tar incremental dumps](https://www.gnu.org/software/tar/manual/html_node/Incremental-Dumps.html). This gives us an additional safety net because `dump` has been a dead project for quite some time and major Linux distros may stop packaging it at any time. If the admin does not specify which compression he prefers, `dump` is chosen if it's installed and the filesystem is ext, otherwise the script proceeds with `tar`.

The snapshotting strategy is also quite simple: If the source dir is on btrfs, the program finds which subvolume it is on (the top-level subvol, id = 5, is also a correct answer in this case) and makes its read-only snapshot. If the underlying filesystem is not btrfs, then we check if it resides on top of a LVM volume, and use lvm snapshotting capabilities (by creating a loopback device on tmpfs and extending volume group on it) if yes. Finally, if we have a directory on a simple partition, no snapshots are done.

On the first run, td-s creates a metadata directory in `/var/lib/td-backup` that contains information about last dump. This is also handy when the host `/` filesystem is readonly, because `dump` by default would try to write to `/etc/dumpdates`.

## License

None.
