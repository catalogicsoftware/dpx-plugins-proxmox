use strict;
use warnings;
use Test::More;

BEGIN {
    # Stub PVE + DpxVstor deps so DpxPlugin compiles without them installed.
    $INC{'PVE/BackupProvider/Plugin/Base.pm'} = 1;
    package PVE::BackupProvider::Plugin::Base; sub new { bless {}, shift }

    $INC{'PVE/INotify.pm'} = 1;
    package PVE::INotify; sub nodename { 'testnode' }

    $INC{'DpxVstor/HttpClient.pm'} = 1;
    package DpxVstor::HttpClient; sub new { bless {}, shift }

    $INC{'DpxVstor/NbdTransfer.pm'} = 1;
    package DpxVstor::NbdTransfer;
}

package main;
use lib '/home/kkazmierczak/services/dpx-proxmox-plugin';
require 'PVE/BackupProvider/Plugin/DpxPlugin.pm';

my $reconcile = \&PVE::BackupProvider::Plugin::DpxPlugin::_reconcile_inventory;

# image_name is authoritative: locate/key the disk by the on-disk image name.
my $inv = $reconcile->(
    [ { device => 'virtio0', image_name => 'drive-virtio0', size_bytes => 100 } ],
    { 'drive-virtio0' => 100, 'foreign' => 5 },
);
is_deeply($inv, { 'drive-virtio0' => { size => 100 } },
    'image_name used, keyed by on-disk image name, foreign ignored');

# Older RP without image_name: fall back to device (no prefix logic).
my $inv2 = $reconcile->(
    [ { device => 'scsi0', size_bytes => 7 } ],
    { 'scsi0' => 7 },
);
is_deeply($inv2, { 'scsi0' => { size => 7 } },
    'fallback to device when image_name absent');

eval {
    $reconcile->(
        [ { device => 'virtio0', image_name => 'drive-virtio0', size_bytes => 100 } ],
        {},
    );
};
like($@, qr/missing/i, 'missing on disk dies');

eval {
    $reconcile->(
        [ { device => 'virtio0', image_name => 'drive-virtio0', size_bytes => 100 } ],
        { 'drive-virtio0' => 64 },
    );
};
like($@, qr/size mismatch/i, 'size mismatch dies');

eval {
    $reconcile->(
        [ { device => 'virtio0', image_name => 'drive-virtio0' } ],
        { 'drive-virtio0' => 100 },
    );
};
like($@, qr/missing size/i, 'manifest disk without size dies');

done_testing;
