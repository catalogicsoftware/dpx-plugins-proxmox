# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Catalogic Software, Inc.
use strict;
use warnings;
use Test::More tests => 10;

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
}

use lib 'lib';
use lib '.';
require PVE::Storage::Custom::DpxPlugin;

my $pkg  = 'PVE::Storage::Custom::DpxPlugin';
my $scfg = { path => '/mnt/pve/dpx-restore-x' };

is_deeply($pkg->plugindata()->{content}, [{ backup => 1, images => 1 }, { backup => 1 }],
    'images is allowed, backup stays the default');
is(scalar $pkg->filesystem_path($scfg, '200/101-local-lvm%3Avm-101-disk-0.raw'),
    '/mnt/pve/dpx-restore-x/vm-101/local-lvm%3Avm-101-disk-0.raw',
    'images volume maps onto the source VM backup directory');
my @list = $pkg->filesystem_path($scfg, '200/101-slot-scsi0.raw');
is_deeply(\@list, ['/mnt/pve/dpx-restore-x/vm-101/slot-scsi0.raw', '200', 'images'],
    'list context returns path, owner vmid and vtype');
is(scalar $pkg->filesystem_path($scfg, 'backup/vzdump-qemu-101.vma'),
    '/base/backup/vzdump-qemu-101.vma', 'non-images volumes pass through to the NFS plugin');
eval { $pkg->filesystem_path($scfg, '200/noprefix.raw') };
like($@, qr/bad image name/, 'an images name without the source vmid prefix is rejected');
eval { $pkg->alloc_image('s', $scfg, 200, 'raw', undef, 1024) };
like($@, qr/read-only restore sources/, 'alloc_image refuses');
eval { $pkg->free_image('s', $scfg, '200/101-slot-scsi0.raw', 0) };
like($@, qr/read-only restore sources/, 'free_image refuses');
is_deeply(\@PVE::Storage::NFSPlugin::freed, [], 'refused images volume never reaches the parent');
is($pkg->free_image('s', $scfg, 'backup/vzdump-qemu-100-2026_01_01-00_00_00.vma.zst', 0),
    'parent-freed', 'free_image on a backup volume returns the parent result');
is_deeply(\@PVE::Storage::NFSPlugin::freed, ['backup/vzdump-qemu-100-2026_01_01-00_00_00.vma.zst'],
    'free_image on a backup volume delegates to the parent');
