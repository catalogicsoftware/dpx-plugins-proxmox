# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Catalogic Software, Inc.
use strict;
use warnings;
use Test::More tests => 8;

# DpxPlugin pulls in PVE modules that only exist on a PVE node. Provide minimal
# in-process stubs so the pure decision sub can be loaded and unit-tested in CI.
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

# ---------------------------------------------------------------------------
# Path A: backup_vm_query_incremental maps the catalog's per-disk verdict to a
# PVE bitmap mode. 'use' (incremental) stays 'use'; everything else, and any
# failure, becomes 'new' so PVE creates a fresh bitmap and streams a full.
# ---------------------------------------------------------------------------

# A catalog "new" verdict (e.g. baseline-genId divergence) must map to PVE 'new'.
{
    my $captured_query;
    my $modes = PVE::BackupProvider::Plugin::DpxPlugin::_resolve_query_incremental_modes(
        storeid    => 'dpx-s',
        vmid       => 100,
        devices    => ['drive-scsi0', 'drive-virtio0'],
        read_genid => sub { my ($d) = @_; return $d eq 'drive-scsi0' ? 'gen-AAA' : 'gen-BBB'; },
        fetch      => sub {
            ($captured_query) = @_;
            return { modes => { 'drive-scsi0' => 'use', 'drive-virtio0' => 'new' } };
        },
        log        => sub {},
    );
    is($modes->{'drive-scsi0'},  'use', 'catalog "use" maps to PVE use (incremental)');
    is($modes->{'drive-virtio0'}, 'new', 'catalog "new" maps to PVE new (fresh bitmap + full)');
    like($captured_query, qr/baselineGenIds=gen-AAA%2Cgen-BBB/,
        'per-disk baseline genIds are sent, comma-aligned with devices');
    like($captured_query, qr/devices=drive-scsi0%2Cdrive-virtio0/,
        'devices are sent sorted and aligned with genIds');
}

# A missing sidecar genId is sent as an empty token, keeping positional alignment.
{
    my $captured_query;
    PVE::BackupProvider::Plugin::DpxPlugin::_resolve_query_incremental_modes(
        storeid    => 'dpx-s',
        vmid       => 100,
        devices    => ['drive-scsi0', 'drive-scsi1'],
        read_genid => sub { my ($d) = @_; return $d eq 'drive-scsi0' ? 'gen-AAA' : undef; },
        fetch      => sub { ($captured_query) = @_; return { modes => {} }; },
        log        => sub {},
    );
    like($captured_query, qr/baselineGenIds=gen-AAA%2C(?:&|$)/,
        'absent sidecar genId is sent as an empty positional token');
}

# A device the catalog omits from the response is forced full (fail safe).
{
    my $modes = PVE::BackupProvider::Plugin::DpxPlugin::_resolve_query_incremental_modes(
        storeid    => 'dpx-s',
        vmid       => 100,
        devices    => ['drive-scsi0'],
        read_genid => sub { undef },
        fetch      => sub { return { modes => {} }; },
        log        => sub {},
    );
    is($modes->{'drive-scsi0'}, 'new', 'device missing from catalog response forces full');
}

# An HTTP failure forces full for every disk rather than risk a diverged overlay.
{
    my $modes = PVE::BackupProvider::Plugin::DpxPlugin::_resolve_query_incremental_modes(
        storeid    => 'dpx-s',
        vmid       => 100,
        devices    => ['drive-scsi0', 'drive-scsi1'],
        read_genid => sub { undef },
        fetch      => sub { die "connection refused" },
        log        => sub {},
    );
    is($modes->{'drive-scsi0'}, 'new', 'disk-mode failure forces full on scsi0');
    is($modes->{'drive-scsi1'}, 'new', 'disk-mode failure forces full on scsi1');
}
