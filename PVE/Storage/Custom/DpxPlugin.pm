# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Catalogic Software, Inc.
package PVE::Storage::Custom::DpxPlugin;

use strict;
use warnings;
use PVE::Cluster;
use base qw(PVE::Storage::NFSPlugin);

our $NODES_DIR = '/etc/pve/nodes';

sub api { return 11; }

sub type { return 'dpx-vstor'; }

sub plugindata {
    return {
        content  => [{ backup => 1, images => 1 }, { backup => 1 }],
        features => { 'backup-provider' => 1 },
    };
}

sub activate_volume    { return 1; }
sub deactivate_volume  { return 1; }
sub list_volumes       { return []; }
sub status             { return (0, 0, 0, 1); }

sub filesystem_path {
    my ($class, $scfg, $volname, $snapname) = @_;
    my ($vtype, $name, $vmid) = $class->parse_volname($volname);
    return $class->SUPER::filesystem_path($scfg, $volname, $snapname) if $vtype ne 'images';
    my ($src, $stem) = $name =~ /^(\d+)-(.+)$/ or die "dpx-vstor: bad image name '$name'\n";
    my $path = "$scfg->{path}/vm-$src/$stem";
    return wantarray ? ($path, $vmid, $vtype) : $path;
}

sub alloc_image { die "dpx-vstor: images are read-only restore sources\n" }

sub free_image {
    my ($class, $storeid, $scfg, $volname, @rest) = @_;
    my ($vtype) = $class->parse_volname($volname);
    return undef if $vtype eq 'images';
    return $class->SUPER::free_image($storeid, $scfg, $volname, @rest);
}

sub volume_has_feature {
    my ($class, $scfg, $feature, $storeid, $volname, @rest) = @_;
    my ($vtype) = $class->parse_volname($volname);
    return undef
        if $vtype eq 'images' && $feature =~ /^(?:clone|rename|snapshot)$/;
    return $class->SUPER::volume_has_feature($scfg, $feature, $storeid, $volname, @rest);
}

sub create_base {
    my ($class, $storeid, $scfg, $volname) = @_;
    my ($vtype) = $class->parse_volname($volname);
    die "dpx-vstor: an instant-restore disk cannot become a template - move it to another storage first\n"
        if $vtype eq 'images';
    return $class->SUPER::create_base($storeid, $scfg, $volname);
}

sub _guests_using_storage {
    my ($storeid) = @_;
    my @users;
    my $vmlist = PVE::Cluster::get_vmlist();
    my $ids = ($vmlist && $vmlist->{ids}) ? $vmlist->{ids} : {};
    my @confs;
    if (%$ids) {
        for my $vmid (sort keys %$ids) {
            my $d = $ids->{$vmid};
            my $dir = ($d->{type} // '') eq 'lxc' ? 'lxc' : 'qemu-server';
            push @confs, [$vmid, "$NODES_DIR/$d->{node}/$dir/$vmid.conf"];
        }
    } else {
        for my $f (glob("$NODES_DIR/*/qemu-server/*.conf"), glob("$NODES_DIR/*/lxc/*.conf")) {
            my ($vmid) = $f =~ m!/(\d+)\.conf$! or next;
            push @confs, [$vmid, $f];
        }
    }
    for my $c (@confs) {
        my ($vmid, $file) = @$c;
        next unless -e $file;
        open(my $fh, '<', $file) or die "dpx-vstor: cannot read $file: $!\n";
        while (my $line = <$fh>) {
            next if $line =~ /^\s*#/;
            my ($val) = $line =~ /^[^:\s]+:\s*(.*)$/ or next;
            if ($val =~ /(?:^|[,=])\Q$storeid\E:/) {
                push @users, $vmid;
                last;
            }
        }
        close($fh);
    }
    return @users;
}

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

    my @users = _guests_using_storage($storeid);
    die "dpx-vstor: storage '$storeid' is still used by guest(s) "
        . join(', ', @users)
        . " - move their disks to another storage or destroy them first\n"
        if @users;

    my $path = "/mnt/pve/$storeid";
    unless (system('umount', $path) == 0) {
        system('umount', '-f', $path) == 0
            or system('umount', '-l', $path);
    }
    rmdir($path);    # only removes the mount point when empty; leaves any stray data

    return undef;
}

1;
