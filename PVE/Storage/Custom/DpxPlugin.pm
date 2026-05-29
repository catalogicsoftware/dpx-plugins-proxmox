# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Catalogic Software, Inc.
package PVE::Storage::Custom::DpxPlugin;

use strict;
use warnings;
use base qw(PVE::Storage::NFSPlugin);

sub api { return 11; }

sub type { return 'dpx-vstor'; }

sub plugindata {
    # PVE convention: content => [allowed-types, default-type]. Both
    # entries are { backup => 1 } because this plugin only handles
    # backups (the default and the only allowed type are the same).
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
    };
}

sub options {
    my $parent_opts = PVE::Storage::NFSPlugin->options();
    return {
        %$parent_opts,
        'dpx-endpoint' => { fixed => 1 },
    };
}

sub new_backup_provider {
    my ($class, $scfg, $storeid, $log_function) = @_;
    require PVE::BackupProvider::Plugin::DpxPlugin;
    return PVE::BackupProvider::Plugin::DpxPlugin->new($scfg, $storeid, $log_function);
}

1;
