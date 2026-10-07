# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Catalogic Software, Inc.
use strict;
use warnings;
use Test::More tests => 15;

BEGIN {
    $INC{'PVE/Cluster.pm'} = 1;
    package PVE::Cluster;
    sub get_vmlist { return { ids => {} } }

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
