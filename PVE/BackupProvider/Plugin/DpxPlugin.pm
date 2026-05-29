# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Catalogic Software, Inc.
package PVE::BackupProvider::Plugin::DpxPlugin;

use strict;
use warnings;

use base qw(PVE::BackupProvider::Plugin::Base);

use File::Path qw(make_path);
use JSON;

use PVE::INotify;

use DpxVstor::HttpClient;
use DpxVstor::NbdTransfer;

# -------------------------------------------------------------------------
# Constructor
# -------------------------------------------------------------------------

sub new {
    my ($class, $scfg, $storeid, $log_function) = @_;
    my $endpoint = $scfg->{'dpx-endpoint'}
        or die "dpx-endpoint not configured on storage $storeid";

    return bless {
        scfg        => $scfg,
        storeid     => $storeid,
        log         => $log_function,
        http        => DpxVstor::HttpClient->new(endpoint => $endpoint),
        node_ip     => _resolve_node_ip(),
        job_token     => undef,
        disk_stats    => {},   # device -> {extents_total, bytes_transferred, bytes_dirty}
        archive_names => {},   # vmid -> archive name
    }, $class;
}

sub provider_name { return 'DPX catalog incremental'; }

# -------------------------------------------------------------------------
# Helpers
# -------------------------------------------------------------------------

sub _resolve_node_ip {
    my $host = PVE::INotify::nodename();
    my @addrs = gethostbyname($host);
    die "DpxPlugin: cannot resolve IP for node '$host'" unless @addrs >= 5;
    return join('.', unpack('C4', $addrs[4]));
}

sub _log {
    my ($self, $level, $msg) = @_;
    $self->{log}->($level, $msg);
}

# -------------------------------------------------------------------------
# Backup lifecycle
# -------------------------------------------------------------------------

sub backup_get_mechanism {
    my ($self, $vmid, $vmtype) = @_;
    return 'nbd';
}

sub job_init {
    my ($self, $start_time) = @_;
    $self->_log('info', "DpxPlugin: job_init storeid=$self->{storeid}");
    my $resp = $self->{http}->post('/proxmox/callback/job/init', {
        storeid => $self->{storeid},
    });
    my $token = $resp->{jobRunToken}
        or die "DpxPlugin: no jobRunToken in job/init response";
    $self->{job_token} = $token;
    $self->_log('info', "DpxPlugin: job_init token=$token");
    return undef;
}

sub job_cleanup {
    my ($self) = @_;
    my $token = $self->{job_token} or return undef;

    $self->_log('info', "DpxPlugin: job_cleanup token=$token");

    # Build disk map for job-done callback (keyed by device name)
    my %disks_map;
    for my $device (sort keys %{$self->{disk_stats}}) {
        my $s = $self->{disk_stats}{$device};
        $disks_map{$device} = {
            bytesWritten => $s->{bytes_transferred} + 0,
            fileSize     => $s->{bytes_transferred} + 0,
        };
    }

    eval {
        $self->{http}->post('/proxmox/callback/job-done', {
            storeid => $self->{storeid},
            token   => $token,
            disks   => \%disks_map,
        });
    };
    $self->_log('warn', "DpxPlugin: job-done callback failed: $@") if $@;

    return undef;
}

sub backup_init {
    my ($self, $vmid, $vmtype, $start_time) = @_;
    my $name = "vm-$vmid-" . ($start_time // time());
    $self->{archive_names}->{$vmid} = $name;
    $self->_log('info', "DpxPlugin: backup_init vmid=$vmid archive=$name");
    return { 'archive-name' => $name };
}

sub backup_cleanup {
    my ($self, $vmid, $vmtype, $success, $info) = @_;
    if ($success) {
        return { stats => { 'archive-size' => 0 } };
    }
    return {};
}

sub backup_vm_query_incremental {
    my ($self, $vmid, $devices) = @_;
    # Each device gets 'use' — let PVE decide based on existing bitmaps.
    # PVE will set bitmap-mode='reuse' if a bitmap exists, 'new' if not.
    my %res;
    for my $device (keys %$devices) {
        $res{$device} = 'use';
    }
    return \%res;
}

sub backup_handle_log_file {
    my ($self, $vmid, $log) = @_;
    return undef;
}

sub backup_vm {
    my ($self, $vmid, $guest_config, $volumes, $info) = @_;
    my $token = $self->{job_token}
        or die "DpxPlugin: backup_vm called without job_token (job_init not called?)";

    for my $device (sort keys %$volumes) {
        my $vol         = $volumes->{$device};
        my $size_bytes  = $vol->{size} // 0;
        my $socket_path = $vol->{'nbd-path'}
            or die "DpxPlugin: no nbd-path on $device";
        my $bitmap_mode = $vol->{'bitmap-mode'} // 'none';
        my $bitmap_name = $vol->{'bitmap-name'} // '';

        my $transfer_action;
        if ($bitmap_mode eq 'reuse') {
            $transfer_action = 'incremental';
        } else {
            $transfer_action = 'base';
        }

        $self->_log('info', sprintf(
            "DpxPlugin: backup_vm vmid=%s device=%s size=%s bitmap-mode=%s bitmap=%s action=%s",
            $vmid, $device, $size_bytes, $bitmap_mode, $bitmap_name, $transfer_action));

        # Tell catalog this disk is starting
        eval {
            $self->{http}->post('/proxmox/callback/disk-start', {
                token      => $token,
                storeid    => $self->{storeid},
                vmid       => $vmid + 0,
                device     => $device,
                bitmapMode => $bitmap_mode,
                bitmapName => $bitmap_name,
                sizeBytes  => $size_bytes + 0,
            });
        };
        $self->_log('warn', "DpxPlugin: disk-start callback failed: $@") if $@;

        # Determine target path: under the NFS-mounted storage path
        # NFSPlugin mounts at $scfg->{path}; images go in vm-<vmid>/
        my $storage_path = $self->{scfg}{path}
            or die "DpxPlugin: no path in scfg (NFS not mounted?)";
        my $target_dir  = "$storage_path/vm-$vmid";
        my $target_path = "$target_dir/$device.img";

        make_path($target_dir) unless -d $target_dir;

        # Perform data transfer directly via UNIX socket
        my $bytes_written = 0;
        eval {
            DpxVstor::NbdTransfer::copy(
                socket_path => $socket_path,
                action      => $transfer_action,
                target_path => $target_path,
                bitmap_name => $bitmap_name,
                export_name => $device,
                size_bytes  => $size_bytes,
                log         => $self->{log},
            );
            # Get written size from file
            $bytes_written = -s $target_path // 0;
        };
        if ($@) {
            die "DpxPlugin: NbdTransfer failed for $device: $@";
        }

        my $file_size = -s $target_path // 0;
        $self->_log('info', sprintf(
            "DpxPlugin: %s done bytes_written=%d file_size=%d",
            $device, $bytes_written, $file_size));

        # Accumulate stats for job_cleanup
        $self->{disk_stats}{$device} = {
            extents_total     => 0,               # NBD transfer doesn't count extents here
            bytes_transferred => $bytes_written,
            bytes_dirty       => $bytes_written,
        };
    }

    return undef;
}

# -------------------------------------------------------------------------
# Restore lifecycle
# -------------------------------------------------------------------------

sub restore_get_mechanism {
    my ($self, $volname) = @_;
    return ('qemu-img', 'qemu');
}

sub restore_vm_init {
    my ($self, $volname) = @_;
    $self->_log('info', "DpxPlugin: restore_vm_init volname=$volname storeid=" . ($self->{storeid} // 'undef'));

    my $resp = $self->{http}->post('/proxmox/restore/init', {
        volname     => $volname,
        pve_node_ip => $self->{node_ip},
        storeid     => $self->{storeid},
    });

    my $session_id = $resp->{session_id}
        or die "DpxPlugin: no session_id in /proxmox/restore/init response";

    $self->{restore_session_id}   = $session_id;
    $self->{restore_volname}      = $volname;
    $self->{restore_guest_config} = $resp->{vm_config};
    $self->_log('info', "DpxPlugin: vm_config received? " . (defined $resp->{vm_config} ? "yes (" . length($resp->{vm_config}) . " bytes)" : "no"));

    # The vmid is encoded in the volname: e.g. snap-<id>-vm-<vmid>.vma
    my $source_vmid = _parse_vmid_from_volname($volname);
    $self->{restore_source_vmid} = $source_vmid;

    $self->_log('info', "DpxPlugin: restore session_id=$session_id vmid=$source_vmid");

    # Discover disk inventory from the NFS-mounted path
    # The storage is NFS-backed via NFSPlugin; images live at $scfg->{path}/vm-<vmid>/
    my $storage_path = $self->{scfg}{path}
        or die "DpxPlugin: no path in scfg (NFS not mounted?)";
    my $vm_dir = "$storage_path/vm-$source_vmid";

    my %inv;
    if (-d $vm_dir) {
        opendir(my $dh, $vm_dir) or die "cannot opendir $vm_dir: $!";
        while (my $entry = readdir($dh)) {
            next unless $entry =~ /^(.+)\.img$/;
            my $device = $1;
            my $path   = "$vm_dir/$entry";
            my @st = stat($path) or next;
            $inv{$device} = { size => $st[7] + 0 };
        }
        closedir $dh;
    }

    $self->_log('info', sprintf("DpxPlugin: restore inventory: %d disks", scalar keys %inv));
    return \%inv;
}

sub restore_vm_volume_init {
    my ($self, $volname, $device_name, $info) = @_;
    die "DpxPlugin: no restore session for $volname" unless $self->{restore_session_id};

    my $vmid      = $self->{restore_source_vmid};
    my $storage_path = $self->{scfg}{path}
        or die "DpxPlugin: no path in scfg";
    my $img_path  = "$storage_path/vm-$vmid/$device_name.img";

    die "DpxPlugin: image not found at $img_path" unless -f $img_path;

    $self->_log('info', "DpxPlugin: restore_vm_volume_init device=$device_name path=$img_path");
    return { 'qemu-img-path' => $img_path };
}

sub restore_vm_volume_cleanup {
    my ($self, $volname, $device_name, $info) = @_;
    return undef;
}

sub restore_vm_cleanup {
    my ($self, $volname) = @_;
    my $session_id = $self->{restore_session_id} or return undef;

    $self->_log('info', "DpxPlugin: restore_vm_cleanup session_id=$session_id");

    eval {
        $self->{http}->post('/proxmox/restore/cleanup', {
            session_id => $session_id,
        });
    };
    $self->_log('warn', "DpxPlugin: restore cleanup failed: $@") if $@;

    delete $self->{restore_session_id};
    delete $self->{restore_volname};
    delete $self->{restore_source_vmid};
    return undef;
}

sub archive_get_guest_config {
    my ($self, $volname) = @_;
    # Guest config is delivered via the /proxmox/restore/init callback response
    # and cached on $self by restore_vm_init.
    return $self->{restore_guest_config};
}

sub archive_get_firewall_config {
    my ($self, $volname) = @_;
    return undef;
}

# -------------------------------------------------------------------------
# Internal helpers
# -------------------------------------------------------------------------

sub _parse_vmid_from_volname {
    my ($volname) = @_;
    # Strip optional storage prefix, leading backup/ dir, and archive extension.
    my $bare = $volname;
    $bare =~ s{^[^:]+:}{};
    $bare =~ s{^backup/}{};
    $bare =~ s{\.vma(?:\..+)?$}{};
    # snap-<snapshotId>-vm-<vmid>
    if ($bare =~ /-vm-(\d+)$/) {
        return $1;
    }
    # vzdump-qemu-<vmid>(-<timestamp>)?
    if ($bare =~ /^vzdump-qemu-(\d+)(?:-|$)/) {
        return $1;
    }
    die "DpxPlugin: cannot parse vmid from volname '$volname'";
}

1;
