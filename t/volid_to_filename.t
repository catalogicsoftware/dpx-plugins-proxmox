# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Catalogic Software, Inc.
use strict;
use warnings;
use Test::More tests => 15;

# DpxPlugin pulls in PVE modules that only exist on a PVE node. Provide minimal
# in-process stubs so the pure naming subs can be loaded and unit-tested in CI.
BEGIN {
    $INC{'PVE/BackupProvider/Plugin/Base.pm'} = 1;
    package PVE::BackupProvider::Plugin::Base;
    sub new { return bless {}, shift }
}
BEGIN {
    $INC{'PVE/INotify.pm'} = 1;
    package PVE::INotify;
    sub nodename { return 'testnode' }
}

use lib 'lib';
use lib '.';
require PVE::BackupProvider::Plugin::DpxPlugin;

my $pkg = 'PVE::BackupProvider::Plugin::DpxPlugin';

# ---------------------------------------------------------------------------
# _volid_to_filename: percent-encode every byte outside [A-Za-z0-9._-] as
# uppercase %XX. The PVE volid ':' storeid separator and any '/' path segment
# become %3A/%2F; '.', '-', '_' stay literal. A volid never contains '%', so the
# encoding is unambiguous and needs no decode on restore.
# ---------------------------------------------------------------------------
is($pkg->can('_volid_to_filename')->('local:100/vm-100-disk-0.raw'),
   'local%3A100%2Fvm-100-disk-0.raw',
   'file volid: colon and slash encoded, dot/dash preserved');
is($pkg->can('_volid_to_filename')->('local-lvm:vm-100-disk-0'),
   'local-lvm%3Avm-100-disk-0',
   'block volid: no extension, colon encoded');
like($pkg->can('_volid_to_filename')->('RAIDZ2:vm-102-disk-0'), qr/%3A/,
   'encoded volid always contains %3A (disjointness invariant)');

# ---------------------------------------------------------------------------
# _disk_file_stem: real volid -> encoded volid stem.
# ---------------------------------------------------------------------------
is($pkg->can('_disk_file_stem')->(102, 'drive-scsi0',
       'PL-VSTOR-1_NFS_PL-PVE-1:102/vm-102-disk-0.vmdk'),
   'PL-VSTOR-1_NFS_PL-PVE-1%3A102%2Fvm-102-disk-0.vmdk',
   'scsi0 data-disk stem from its nfs volid');
is($pkg->can('_disk_file_stem')->(102, 'drive-efidisk0', 'RAIDZ2:vm-102-disk-0'),
   'RAIDZ2%3Avm-102-disk-0',
   'efidisk0 stem from its raidz2 volid');

# The reported bug: two disks both named vm-102-disk-0 on different storages
# must now produce DISTINCT on-disk stems (previously both -> vm-102-disk-0).
my $scsi_stem = $pkg->can('_disk_file_stem')->(102, 'drive-scsi0',
    'PL-VSTOR-1_NFS_PL-PVE-1:102/vm-102-disk-0.vmdk');
my $efi_stem  = $pkg->can('_disk_file_stem')->(102, 'drive-efidisk0',
    'RAIDZ2:vm-102-disk-0');
isnt($scsi_stem, $efi_stem,
   'multi-storage disk-0 collision resolved: distinct stems');

# ---------------------------------------------------------------------------
# Fallback: null / empty / non-volid value -> slot-<slot>, provably disjoint
# from encoded volids (which always carry %3A; a slot name carries no %).
# ---------------------------------------------------------------------------
is($pkg->can('_disk_file_stem')->(102, 'drive-scsi0', undef),
   'slot-scsi0', 'null volid falls back to slot-<slot>');
is($pkg->can('_disk_file_stem')->(102, 'drive-scsi0', ''),
   'slot-scsi0', 'empty volid falls back to slot-<slot>');
is($pkg->can('_disk_file_stem')->(102, 'drive-scsi1', '/dev/sdb'),
   'slot-scsi1', 'passthrough path is not a volid: falls back to slot-<slot>');
unlike($pkg->can('_disk_file_stem')->(102, 'drive-efidisk0', undef), qr/%/,
   'fallback stem contains no % (disjoint from encoded-volid namespace)');

# ---------------------------------------------------------------------------
# _parse_volid_by_slot: efidisk0/tpmstate0 now resolved; none/passthrough nulled.
# ---------------------------------------------------------------------------
my $cfg = join("\n",
    'scsi0: PL-VSTOR-1_NFS_PL-PVE-1:102/vm-102-disk-0.vmdk,size=20G',
    'efidisk0: RAIDZ2:vm-102-disk-0,efitype=4m,size=1M',
    'tpmstate0: RAIDZ2:vm-102-disk-1,size=4M,version=v2.0',
    'ide2: none,media=cdrom',
    'scsi1: /dev/sdb',
    'net0: virtio=AA:BB:CC:DD:EE:FF,bridge=vmbr0',
);
my $map = $pkg->can('_parse_volid_by_slot')->($cfg);
is($map->{efidisk0},  'RAIDZ2:vm-102-disk-0', 'efidisk0 volid parsed');
is($map->{tpmstate0}, 'RAIDZ2:vm-102-disk-1', 'tpmstate0 volid parsed');
is($map->{scsi0},     'PL-VSTOR-1_NFS_PL-PVE-1:102/vm-102-disk-0.vmdk',
   'scsi0 volid parsed');
ok(!defined $map->{ide2},  'none value nulled');
ok(!defined $map->{scsi1}, 'passthrough /dev path nulled');
