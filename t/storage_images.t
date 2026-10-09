# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Catalogic Software, Inc.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

BEGIN {
    $INC{'PVE/Storage/NFSPlugin.pm'} = 1;
    package PVE::Storage::NFSPlugin;
    sub options { return {} }
    sub parse_volname {
        my ($class, $volname) = @_;
        return ('images', $2, $1) if $volname =~ m!^(\d+)/([^/\s]+\.raw)$!;
        return ('backup', $1, undef) if $volname =~ m!^backup/(\S+)$!;
        die "unable to parse volname '$volname'\n";
    }
    sub filesystem_path { return "/base/$_[2]" }
    sub free_image { return 'parent-freed' }
    sub volume_has_feature { return 'parent-feature' }
    sub create_base { return 'parent-base' }
}

use lib '.';
require PVE::Storage::Custom::DpxPlugin;

my $pkg  = 'PVE::Storage::Custom::DpxPlugin';
my $scfg = { path => '/mnt/pve/dpx-restore-x' };
my $img  = '200/101-slot-scsi0.raw';
my $bak  = 'backup/vzdump-qemu-100-2026_01_01-00_00_00.vma.zst';

is_deeply($pkg->plugindata()->{content}, [{ backup => 1, images => 1 }, { backup => 1 }],
    'images is allowed, backup stays the default');
my @list = $pkg->filesystem_path($scfg, $img);
is_deeply(\@list, ['/mnt/pve/dpx-restore-x/vm-101/slot-scsi0.raw', '200', 'images'],
    'list context returns path, owner vmid and vtype');

for my $c (
    [filesystem_path => [$scfg, '200/101-local-lvm%3Avm-101-disk-0.raw'], '/mnt/pve/dpx-restore-x/vm-101/local-lvm%3Avm-101-disk-0.raw'],
    [filesystem_path => [$scfg, 'backup/vzdump-qemu-101.vma'], '/base/backup/vzdump-qemu-101.vma'],
    [free_image => ['s', $scfg, $img, 0], undef],
    [free_image => ['s', $scfg, $bak, 0], 'parent-freed'],
    [volume_has_feature => [$scfg, 'snapshot', 's', $img], undef],
    [volume_has_feature => [$scfg, 'copy', 's', $img], 'parent-feature'],
    [volume_has_feature => [$scfg, 'snapshot', 's', $bak], 'parent-feature'],
    [create_base => ['s', $scfg, $bak], 'parent-base'],
) { my ($m, $a, $w) = @$c; is(scalar $pkg->$m(@$a), $w, "$m $a->[-1]") }
for my $c (
    [filesystem_path => [$scfg, '200/noprefix.raw'], qr/bad image name/],
    [alloc_image => ['s', $scfg, 200, 'raw', undef, 1024], qr/read-only restore sources/],
    [create_base => ['s', $scfg, $img], qr/cannot become a template/],
) { my ($m, $a, $re) = @$c; eval { $pkg->$m(@$a) }; like($@, $re, "$m dies") }

my $nodes = tempdir(CLEANUP => 1);
make_path("$nodes/pve1/qemu-server", "$nodes/pve1/lxc", "$nodes/pve2/qemu-server");
{ no warnings 'once'; $PVE::Storage::Custom::DpxPlugin::NODES_DIR = $nodes; }
sub write_conf { open(my $fh, '>', $_[0]) or die "cannot write $_[0]: $!"; print $fh $_[1]; close($fh); $_[0] }
write_conf("$nodes/pve1/qemu-server/200.conf", "scsi0: dpx-restore-x:200/101-slot-scsi0.raw,size=3G\n");
write_conf("$nodes/pve1/qemu-server/201.conf", "scsi0: local-lvm:vm-201-disk-0,size=3G\n");
write_conf("$nodes/pve1/lxc/204.conf", "rootfs: dpx-restore-x:204/101-slot-rootfs.raw\n");
write_conf("$nodes/pve1/qemu-server/205.conf", "#scsi9: dpx-restore-x:note\nscsi0: dpx-restore-xy:205/1-a.raw\n");
write_conf("$nodes/pve2/qemu-server/207.conf", "scsi1: local,import-from=dpx-restore-ab:207/1-a.raw\n");
is_deeply([sort { $a <=> $b } PVE::Storage::Custom::DpxPlugin::_guests_using_storage('dpx-restore-x')], [200, 204],
    'qemu and lxc configs referencing the storage are reported; comments, other ids and prefixes are not');
is_deeply([PVE::Storage::Custom::DpxPlugin::_guests_using_storage('dpx-restore-a')], [],
    'a storage id that is a prefix of another does not match');
is_deeply([PVE::Storage::Custom::DpxPlugin::_guests_using_storage('dpx-restore-ab')], [207],
    'a storage id after = (import-from) on another node matches');
eval { $pkg->on_delete_hook('dpx-restore-x', $scfg) };
like($@, qr/still used by guest\(s\) 200, 204 /, 'the storage delete is refused and names the guests');
my $locked = write_conf("$nodes/pve1/qemu-server/203.conf", "scsi0: dpx-restore-x:203/101-slot-scsi0.raw\n");
chmod(0000, $locked);
SKIP: {
    skip 'root can read a mode-0000 file', 1 if open(my $probe, '<', $locked);
    eval { $pkg->on_delete_hook('dpx-restore-x', $scfg) };
    like($@, qr/cannot read \Q$locked\E/, 'the storage delete is refused while a config cannot be read');
}
chmod(0600, $locked);

done_testing;
