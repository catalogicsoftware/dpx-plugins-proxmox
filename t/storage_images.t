# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Catalogic Software, Inc.
use strict;
use warnings;
use Test::More tests => 18;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

BEGIN {
    $INC{'PVE/Cluster.pm'} = 1;
    package PVE::Cluster;
    our $vmlist = { ids => {} };
    sub get_vmlist { return $vmlist }

    $INC{'PVE/Storage/NFSPlugin.pm'} = 1;
    package PVE::Storage::NFSPlugin;
    sub options { return {} }
    sub parse_volname {
        my ($class, $volname) = @_;
        return ('images', $2, $1) if $volname =~ m!^(\d+)/([^/\s]+\.raw)$!;
        return ('backup', $1, undef) if $volname =~ m!^backup/(\S+)$!;
        die "unable to parse volname '$volname'\n";
    }
    sub filesystem_path {
        my ($class, $scfg, $volname) = @_;
        return "/base/$volname";
    }
    our @freed;
    sub free_image {
        my ($class, $storeid, $scfg, $volname, @rest) = @_;
        push @freed, $volname;
        return 'parent-freed';
    }
    sub volume_has_feature { return 'parent-feature' }
    our @based;
    sub create_base {
        my ($class, $storeid, $scfg, $volname) = @_;
        push @based, $volname;
        return 'parent-base';
    }
}

use lib 'lib';
use lib '.';
require PVE::Storage::Custom::DpxPlugin;

my $pkg  = 'PVE::Storage::Custom::DpxPlugin';
my $scfg = { path => '/mnt/pve/dpx-restore-x' };
my $img  = '200/101-slot-scsi0.raw';
my $bak  = 'backup/vzdump-qemu-100-2026_01_01-00_00_00.vma.zst';

is_deeply($pkg->plugindata()->{content}, [{ backup => 1, images => 1 }, { backup => 1 }],
    'images is allowed, backup stays the default');
is(scalar $pkg->filesystem_path($scfg, '200/101-local-lvm%3Avm-101-disk-0.raw'),
    '/mnt/pve/dpx-restore-x/vm-101/local-lvm%3Avm-101-disk-0.raw',
    'images volume maps onto the source VM backup directory');
my @list = $pkg->filesystem_path($scfg, $img);
is_deeply(\@list, ['/mnt/pve/dpx-restore-x/vm-101/slot-scsi0.raw', '200', 'images'],
    'list context returns path, owner vmid and vtype');
is(scalar $pkg->filesystem_path($scfg, 'backup/vzdump-qemu-101.vma'),
    '/base/backup/vzdump-qemu-101.vma', 'non-images volumes pass through to the NFS plugin');
eval { $pkg->filesystem_path($scfg, '200/noprefix.raw') };
like($@, qr/bad image name/, 'an images name without the source vmid prefix is rejected');
eval { $pkg->alloc_image('s', $scfg, 200, 'raw', undef, 1024) };
like($@, qr/read-only restore sources/, 'alloc_image refuses');
is($pkg->free_image('s', $scfg, $img, 0), undef, 'free_image on an images volume is a no-op');
is_deeply(\@PVE::Storage::NFSPlugin::freed, [], 'an images volume never reaches the parent free');
is($pkg->free_image('s', $scfg, $bak, 0), 'parent-freed',
    'free_image on a backup volume returns the parent result');
is_deeply(\@PVE::Storage::NFSPlugin::freed, [$bak], 'free_image on a backup volume delegates');
is($pkg->volume_has_feature($scfg, 'snapshot', 's', $img), undef,
    'snapshot is not offered for images');
is($pkg->volume_has_feature($scfg, 'copy', 's', $img), 'parent-feature',
    'copy (full clone, move) still delegates for images');
is($pkg->volume_has_feature($scfg, 'snapshot', 's', $bak), 'parent-feature',
    'backup volumes keep the parent features');
eval { $pkg->create_base('s', $scfg, $img) };
like($@, qr/cannot become a template/, 'create_base refuses images');
is($pkg->create_base('s', $scfg, $bak), 'parent-base', 'create_base delegates for other volumes');

my $nodes = tempdir(CLEANUP => 1);
make_path("$nodes/pve1/qemu-server");
{ no warnings 'once'; $PVE::Storage::Custom::DpxPlugin::NODES_DIR = $nodes; }
sub write_conf {
    my ($vmid, $body) = @_;
    my $f = "$nodes/pve1/qemu-server/$vmid.conf";
    open(my $fh, '>', $f) or die "cannot write $f: $!";
    print $fh $body;
    close($fh);
    return $f;
}
write_conf(200, "scsi0: dpx-restore-x:200/101-slot-scsi0.raw,size=3G\n");
write_conf(201, "scsi0: local-lvm:vm-201-disk-0,size=3G\n");
$PVE::Cluster::vmlist = { ids => {
    200 => { node => 'pve1', type => 'qemu' },
    201 => { node => 'pve1', type => 'qemu' },
    202 => { node => 'pve1', type => 'qemu' },
} };
is_deeply([PVE::Storage::Custom::DpxPlugin::_guests_using_storage('dpx-restore-x')], [200],
    'a guest whose config references the storage is reported; a vanished config is skipped');
my $locked = write_conf(203, "scsi0: dpx-restore-x:203/101-slot-scsi0.raw\n");
$PVE::Cluster::vmlist->{ids}{203} = { node => 'pve1', type => 'qemu' };
chmod(0000, $locked);
SKIP: {
    skip 'root can read a mode-0000 file', 2 if open(my $probe, '<', $locked);
    eval { PVE::Storage::Custom::DpxPlugin::_guests_using_storage('dpx-restore-x') };
    like($@, qr/cannot read \Q$locked\E/, 'an unreadable guest config refuses instead of passing');
    eval { $pkg->on_delete_hook('dpx-restore-x', $scfg) };
    like($@, qr/cannot read/, 'the storage delete is refused while a config cannot be read');
}
chmod(0600, $locked);
