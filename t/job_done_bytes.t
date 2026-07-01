# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Catalogic Software, Inc.
use strict;
use warnings;
use Test::More tests => 6;

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

{
    my $disk_stats = {
        'drive-scsi0' => { bytes_written => 107_413_504, file_size => 8_589_934_592 },
    };
    my $map = PVE::BackupProvider::Plugin::DpxPlugin::_build_disks_map($disk_stats);
    is($map->{'drive-scsi0'}{bytesWritten}, 107_413_504,
        'bytesWritten is the real NBD-streamed count');
    is($map->{'drive-scsi0'}{fileSize}, 8_589_934_592,
        'fileSize is the logical on-disk image size');
    isnt($map->{'drive-scsi0'}{bytesWritten}, $map->{'drive-scsi0'}{fileSize},
        'bytesWritten and fileSize are distinct for an incremental');
}

{
    my $disk_stats = {
        'drive-scsi0' => { bytes_written => 0, file_size => 4_294_967_296 },
    };
    my $map = PVE::BackupProvider::Plugin::DpxPlugin::_build_disks_map($disk_stats);
    is($map->{'drive-scsi0'}{bytesWritten}, 0,
        'zero-change incremental reports 0 bytesWritten');
    is($map->{'drive-scsi0'}{fileSize}, 4_294_967_296,
        'zero-change incremental still reports the logical fileSize (restore-safe)');
}

{
    my $disk_stats = {
        'drive-scsi0' => { bytes_written => '102', file_size => '4096' },
    };
    my $map = PVE::BackupProvider::Plugin::DpxPlugin::_build_disks_map($disk_stats);
    cmp_ok($map->{'drive-scsi0'}{bytesWritten}, '==', 102,
        'bytesWritten is numerically coerced');
}
