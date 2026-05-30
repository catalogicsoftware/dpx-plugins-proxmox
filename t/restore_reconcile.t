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

my $inv = $reconcile->([ { device => 'scsi0', size_bytes => 100 } ], { scsi0 => 100, foreign => 999 });
is_deeply($inv, { scsi0 => { size => 100 } }, 'foreign img ignored, manifest disk kept');

eval { $reconcile->([ { device => 'scsi0', size_bytes => 100 } ], {}); };
like($@, qr/missing/i, 'missing manifest disk dies');

eval { $reconcile->([ { device => 'scsi0', size_bytes => 100 } ], { scsi0 => 64 }); };
like($@, qr/size mismatch/i, 'size mismatch dies');

eval { $reconcile->([ { device => 'scsi0' } ], { scsi0 => 100 }); };
like($@, qr/missing size/i, 'manifest disk without size dies');

my $inv2 = $reconcile->([ { device => 'virtio0', size_bytes => 100 } ], { 'drive-virtio0' => 100, 'foreign' => 5 });
is_deeply($inv2, { 'drive-virtio0' => { size => 100 } }, 'manifest virtio0 matches on-disk drive-virtio0, keyed by on-disk name');

my $inv3 = $reconcile->([ { device => 'scsi0', size_bytes => 7 } ], { 'scsi0' => 7 });
is_deeply($inv3, { 'scsi0' => { size => 7 } }, 'exact-name match still works');

done_testing;
