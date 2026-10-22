# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Catalogic Software, Inc.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);

my @calls;
my $activate_error;

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
BEGIN {
    $INC{'PVE/Storage.pm'} = 1;
    package PVE::Storage;
    sub config { return { ids => {} } }
    sub activate_storage {
        my ($cfg, $storeid) = @_;
        push @calls, "activate:$storeid";
        die $activate_error if defined $activate_error;
        return 1;
    }
}

use lib 'lib';
use lib '.';
require PVE::BackupProvider::Plugin::DpxPlugin;

package FakeHttp {
    sub new { return bless {}, shift }
    sub post {
        my ($self, $path) = @_;
        push @calls, "post:$path";
        return { session_id => 's-1', vmid => 101, disks => [], vm_config => '' };
    }
}

my $pkg     = 'PVE::BackupProvider::Plugin::DpxPlugin';
my $storeid = 'dpx-restore-x-101';
my $path    = tempdir(CLEANUP => 1);

sub provider {
    return bless {
        scfg    => { path => $path },
        storeid => $storeid,
        log     => sub {},
        http    => FakeHttp->new,
        node_ip => '10.0.0.2',
    }, $pkg;
}

{
    no warnings 'redefine';
    local *PVE::BackupProvider::Plugin::DpxPlugin::_assert_mounted = sub {
        push @calls, "assert:$_[0]";
        return 1;
    };

    @calls = ();
    my $inv = provider()->restore_vm_init('backup/vm-101');
    is_deeply(\@calls,
        ['post:/proxmox/restore/init', "activate:$storeid", "assert:$path"],
        'the restore storage is activated on this node before its mount is asserted');
    is_deeply($inv, {}, 'restore_vm_init still returns the inventory');

    @calls = ();
    $activate_error = "storage '$storeid' is not online\n";
    eval { provider()->restore_vm_init('backup/vm-101') };
    like($@, qr/^DpxPlugin: cannot activate storage '\Q$storeid\E': storage '\Q$storeid\E' is not online/,
        'an activation failure fails the restore and names the storage');
    is_deeply(\@calls, ['post:/proxmox/restore/init', "activate:$storeid"],
        'the mount is not asserted after a failed activation');
    $activate_error = undef;
}

eval { PVE::BackupProvider::Plugin::DpxPlugin::_assert_mounted($path) };
like($@, qr/is not a mountpoint/,
    'an existing directory that is not itself a mount point fails the assertion');
ok(PVE::BackupProvider::Plugin::DpxPlugin::_assert_mounted('/'),
    'a real mount point passes the assertion');

done_testing;
