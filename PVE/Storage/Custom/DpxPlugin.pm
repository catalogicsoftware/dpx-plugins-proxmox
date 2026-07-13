# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Catalogic Software, Inc.
package PVE::Storage::Custom::DpxPlugin;

use strict;
use warnings;
use base qw(PVE::Storage::NFSPlugin);

sub api { return 11; }

sub type { return 'dpx-vstor'; }

sub plugindata {
    return {
        content  => [{ backup => 1 }, { backup => 1 }],
        features => { 'backup-provider' => 1 },
    };
}

sub activate_volume    { return 1; }
sub deactivate_volume  { return 1; }
sub list_volumes       { return []; }
sub status             { return (0, 0, 0, 1); }

sub properties {
    return {
        'dpx-endpoint' => {
            description => 'DPX catalog HTTP endpoint (e.g. http://dpx-catalog.example.com:8080)',
            type        => 'string',
        },
        'dpx-node-ip' => {
            description => 'The IP this PVE node advertises to the DPX catalog for the restore data path',
            type        => 'string',
            optional    => 1,
        },
        'dpx-restore-token' => {
            description => 'Per-restore authorization token issued by the DPX catalog at dispatch',
            type        => 'string',
            optional    => 1,
        },
        'dpx-job-token' => {
            description => 'Per-job authorization token issued by the DPX catalog at provision, sent as X-DPX-Job-Token on backup callbacks',
            type        => 'string',
            optional    => 1,
        },
    };
}

sub options {
    my $parent_opts = PVE::Storage::NFSPlugin->options();
    return {
        %$parent_opts,
        'dpx-endpoint'      => { fixed => 1 },
        'dpx-node-ip'       => { optional => 1 },
        'dpx-restore-token' => { optional => 1 },
        'dpx-job-token'     => { optional => 1 },
    };
}

sub new_backup_provider {
    my ($class, $scfg, $storeid, $log_function) = @_;
    require PVE::BackupProvider::Plugin::DpxPlugin;
    return PVE::BackupProvider::Plugin::DpxPlugin->new($scfg, $storeid, $log_function);
}

# PVE's storage delete drops the config entry but leaves the NFS mount at
# /mnt/pve/<storeid> in place. DPX registers a fresh per-run storage id for
# every VM backup and deletes it afterwards, so a leftover mount accumulates
# each run; once the backing vStor export is torn down the mount turns into a
# stale NFS handle (ESTALE) and blocks any future add of the same storeid.
# Unmount and remove the mount point here so per-run ids stay reusable.
sub on_delete_hook {
    my ($class, $storeid, $scfg) = @_;

    my $path = "/mnt/pve/$storeid";
    unless (system('umount', $path) == 0) {
        system('umount', '-f', $path) == 0
            or system('umount', '-l', $path);
    }
    rmdir($path);    # only removes the mount point when empty; leaves any stray data

    return undef;
}

1;
