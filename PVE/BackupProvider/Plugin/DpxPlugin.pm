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
use DpxVstor::PluginVersion;
use DpxVstor::IntegrityGate;
use DpxVstor::GenIdSidecar;

sub new {
    my ($class, $scfg, $storeid, $log_function) = @_;
    my $endpoint = $scfg->{'dpx-endpoint'}
        or die "dpx-endpoint not configured on storage $storeid";

    my $node_ip = (defined $scfg->{'dpx-node-ip'} && length $scfg->{'dpx-node-ip'})
        ? $scfg->{'dpx-node-ip'}
        : _resolve_node_ip();

    return bless {
        scfg        => $scfg,
        storeid     => $storeid,
        log         => $log_function,
        http        => DpxVstor::HttpClient->new(endpoint => $endpoint),
        node_ip     => $node_ip,
        job_token     => undef,
        disk_stats    => {},
    }, $class;
}

sub provider_name { return 'DPX catalog incremental'; }

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

sub backup_get_mechanism {
    my ($self, $vmid, $vmtype) = @_;
    return 'nbd';
}

sub job_init {
    my ($self, $start_time) = @_;
    $self->_log('info', "DpxPlugin: job_init storeid=$self->{storeid}");
    my $resp = $self->{http}->post('/proxmox/callback/job/init', {
        storeid       => $self->{storeid},
        pluginVersion => DpxVstor::PluginVersion::deb_version(),
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

    my %disks_map;
    for my $device (sort keys %{$self->{disk_stats}}) {
        my $bytes = $self->{disk_stats}{$device} + 0;
        $disks_map{$device} = {
            bytesWritten => $bytes,
            fileSize     => $bytes,
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
    $self->_log('info', "DpxPlugin: backup_init vmid=$vmid archive=$name");
    return { 'archive-name' => $name };
}

sub backup_cleanup {
    my ($self, $vmid, $vmtype, $success, $info) = @_;
    if ($success) {
        return { stats => { 'archive-size' => 0 } };
    }
    $self->_log('warn', sprintf(
        "DpxPlugin: backup FAILED for vmid=%s (token=%s) — no job-done sent; "
        . "catalog will discard this run on timeout",
        $vmid, ($self->{job_token} // 'none')));
    return {};
}

sub backup_vm_query_incremental {
    my ($self, $vmid, $devices) = @_;

    my $storage_path = $self->{scfg}{path};

    my $read_genid = sub {
        my ($device) = @_;
        return undef unless defined $storage_path;
        my $genid_path =
            DpxVstor::GenIdSidecar::sidecar_path($storage_path, $vmid, $device);
        return DpxVstor::GenIdSidecar::read_genid($genid_path);
    };

    my $fetch_modes = sub {
        my ($query) = @_;
        return $self->{http}->get('/proxmox/callback/disk-mode' . $query);
    };

    return _resolve_query_incremental_modes(
        storeid    => $self->{storeid},
        vmid       => $vmid,
        devices    => [keys %$devices],
        read_genid => $read_genid,
        fetch      => $fetch_modes,
        log        => $self->{log},
    );
}

sub _resolve_query_incremental_modes {
    my (%args) = @_;
    my $storeid    = $args{storeid};
    my $vmid       = $args{vmid};
    my @devices    = @{ $args{devices} };
    my $read_genid = $args{read_genid};
    my $fetch      = $args{fetch};
    my $log        = $args{log} // sub {};

    @devices = sort @devices;

    my @genids = map { $read_genid->($_) // '' } @devices;

    my $query =
          '?storeid=' . _uri_escape($storeid)
        . '&vmid=' . ($vmid + 0)
        . '&devices=' . _uri_escape(join(',', @devices))
        . '&baselineGenIds=' . _uri_escape(join(',', @genids));

    my %res = map { $_ => 'new' } @devices;

    my $resp = eval { $fetch->($query) };
    if ($@ || ref($resp) ne 'HASH' || ref($resp->{modes}) ne 'HASH') {
        $log->('warn', "DpxPlugin: disk-mode query failed; forcing full for all disks: "
            . ($@ // 'malformed response'));
        return \%res;
    }

    my $modes = $resp->{modes};
    for my $device (@devices) {
        my $mode = $modes->{$device};
        $res{$device} = (defined $mode && $mode eq 'use') ? 'use' : 'new';
    }
    return \%res;
}

sub _uri_escape {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/([^A-Za-z0-9_.~-])/sprintf('%%%02X', ord($1))/ge;
    return $value;
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

        my $storage_path = $self->{scfg}{path}
            or die "DpxPlugin: no path in scfg (NFS not mounted?)";
        my $target_dir  = "$storage_path/vm-$vmid";
        my $target_path = "$target_dir/$device.img";

        make_path($target_dir) unless -d $target_dir;

        my $genid_path = DpxVstor::GenIdSidecar::sidecar_path(
            $storage_path, $vmid, $device);
        my $baseline_genid = DpxVstor::GenIdSidecar::read_genid($genid_path);

        my $disk_start_action;
        eval {
            my $resp = $self->{http}->post('/proxmox/callback/disk-start', {
                token         => $token,
                storeid       => $self->{storeid},
                vmid          => $vmid + 0,
                device        => $device,
                bitmapMode    => $bitmap_mode,
                bitmapName    => $bitmap_name,
                sizeBytes     => $size_bytes + 0,
                baselineGenId => $baseline_genid,
            });
            if (ref($resp) eq 'HASH') {
                $disk_start_action = $resp->{action};
                if (defined $resp->{genId} && $resp->{genId} ne '') {
                    DpxVstor::GenIdSidecar::write_genid($genid_path, $resp->{genId});
                }
            }
        };
        $self->_log('warn', "DpxPlugin: disk-start callback failed: $@") if $@;

        my $effective_bitmap_mode = $bitmap_mode;
        if (defined $disk_start_action
            && $disk_start_action eq 'base'
            && $bitmap_mode eq 'reuse') {
            $self->_log('warn', sprintf(
                "DpxPlugin: catalog forced full for %s but PVE handed bitmap-mode=reuse; "
              . "overriding to full rebuild (data-path backstop)", $device));
            $effective_bitmap_mode = 'new';
            $transfer_action = 'base';
        }

        my $pre_overlay_alloc = ($effective_bitmap_mode eq 'reuse' && -e $target_path)
            ? DpxVstor::IntegrityGate::allocated_bytes($target_path)
            : 0;

        my $bytes_written = 0;
        my $transfer_summary = {};
        eval {
            $transfer_summary = DpxVstor::NbdTransfer::copy(
                socket_path => $socket_path,
                action      => $transfer_action,
                bitmap_mode => $effective_bitmap_mode,
                target_path => $target_path,
                bitmap_name => $bitmap_name,
                export_name => $device,
                size_bytes  => $size_bytes,
                log         => $self->{log},
            );
            $transfer_summary = {} unless ref($transfer_summary) eq 'HASH';
            $bytes_written = -s $target_path // 0;
        };
        if ($@) {
            die "DpxPlugin: NbdTransfer failed for $device: $@";
        }

        my $punched_zero_bytes = $transfer_summary->{punched_zero_bytes} // 0;
        my $integ = DpxVstor::IntegrityGate::check(
            target_path          => $target_path,
            base_allocated_bytes => $pre_overlay_alloc,
            punched_zero_bytes   => $punched_zero_bytes,
            action               => $transfer_action,
            dirty_extents        => [],
            expected_head        => '',
            log                  => $self->{log},
        );
        eval {
            $self->{http}->post('/proxmox/callback/integrity-result', {
                token            => $token,
                storeid          => $self->{storeid},
                device           => $device,
                passed           => $integ->{passed} ? JSON::true : JSON::false,
                allocatedBytes   => $integ->{allocated_bytes} + 0,
                punchedZeroBytes => $punched_zero_bytes + 0,
                message          => $integ->{message} // '',
            });
        };
        $self->_log('warn',
            "DpxPlugin: integrity-result POST failed for $device (catalog will "
          . "fail closed on the missing result): $@") if $@;
        die "DpxPlugin: integrity gate FAILED for $device: $integ->{message}"
            unless $integ->{passed};

        my $file_size = -s $target_path // 0;
        $self->_log('info', sprintf(
            "DpxPlugin: %s done bytes_written=%d file_size=%d",
            $device, $bytes_written, $file_size));

        $self->{disk_stats}{$device} = $bytes_written;
    }

    return undef;
}

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

    die "DpxPlugin: /proxmox/restore/init did not return a JSON object"
        unless ref($resp) eq 'HASH';

    my $session_id = $resp->{session_id}
        or die "DpxPlugin: no session_id in /proxmox/restore/init response";
    die "DpxPlugin: no vmid in /proxmox/restore/init response"
        unless defined $resp->{vmid};
    die "DpxPlugin: no disks array in /proxmox/restore/init response"
        unless ref($resp->{disks}) eq 'ARRAY';

    my ($source_vmid) = (($resp->{vmid} // '') =~ /^(\d+)$/)
        or die "DpxPlugin: invalid vmid in /proxmox/restore/init response: " . ($resp->{vmid} // 'undef');

    $self->{restore}{$volname} = {
        session_id   => $session_id,
        source_vmid  => $source_vmid,
        guest_config => $resp->{vm_config},
    };
    $self->_log('info', "DpxPlugin: vm_config received? " . (defined $resp->{vm_config} ? "yes (" . length($resp->{vm_config}) . " bytes)" : "no"));
    $self->_log('info', "DpxPlugin: restore session_id=$session_id vmid=$source_vmid");

    my $storage_path = $self->{scfg}{path}
        or die "DpxPlugin: no path in scfg (NFS not mounted?)";
    _assert_mounted($storage_path);
    my $vm_dir = "$storage_path/vm-$source_vmid";

    my %fs_sizes;
    if (-d $vm_dir) {
        opendir(my $dh, $vm_dir) or die "cannot opendir $vm_dir: $!";
        while (my $entry = readdir($dh)) {
            next unless $entry =~ /^(.+)\.img$/;
            my $device = $1;
            my @st = stat("$vm_dir/$entry") or next;
            my ($sz) = ($st[7] =~ /^(\d+)$/)
                or die "DpxPlugin: bad size for $entry";
            $fs_sizes{$device} = $sz;
        }
        closedir $dh;
    }

    my $inv = _reconcile_inventory($resp->{disks}, \%fs_sizes);

    $self->_log('info', sprintf("DpxPlugin: restore inventory: %d disks", scalar keys %$inv));
    return $inv;
}

sub restore_vm_volume_init {
    my ($self, $volname, $device_name, $info) = @_;
    my $restore = $self->{restore}{$volname};
    die "DpxPlugin: no restore session for $volname" unless $restore;

    my $vmid      = $restore->{source_vmid};
    my $storage_path = $self->{scfg}{path}
        or die "DpxPlugin: no path in scfg";
    my ($safe_device) = ($device_name =~ /^([\w.\-]+)$/)
        or die "DpxPlugin: invalid device name '$device_name'";
    my $img_path  = "$storage_path/vm-$vmid/$safe_device.img";

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
    my $restore = $self->{restore}{$volname} or return undef;
    my $session_id = $restore->{session_id} or return undef;

    $self->_log('info', "DpxPlugin: restore_vm_cleanup session_id=$session_id");

    eval {
        $self->{http}->post('/proxmox/restore/cleanup', {
            session_id => $session_id,
        });
    };
    $self->_log('warn', "DpxPlugin: restore cleanup failed: $@") if $@;

    delete $self->{restore}{$volname};
    return undef;
}

sub archive_get_guest_config {
    my ($self, $volname) = @_;
    my $restore = $self->{restore}{$volname} or return undef;
    return $restore->{guest_config};
}

sub archive_get_firewall_config {
    my ($self, $volname) = @_;
    return undef;
}

sub _assert_mounted {
    my ($path) = @_;
    my $out = `findmnt --target "$path" 2>/dev/null`;
    die "DpxPlugin: path '$path' is not a mountpoint (NFS not mounted?)"
        unless defined $out && $out =~ /\S/;
    return 1;
}

sub _reconcile_inventory {
    my ($manifest_disks, $fs_sizes) = @_;
    my %inv;
    for my $disk (@{$manifest_disks // []}) {
        my $device = $disk->{device};
        my $expected = $disk->{size_bytes} // $disk->{sizeBytes};
        die "DpxPlugin: manifest disk missing device name"
            unless defined $device;
        die "DpxPlugin: manifest disk '$device' missing size"
            unless defined $expected;
        my $key = (defined $disk->{image_name} && length $disk->{image_name})
            ? $disk->{image_name}
            : $device;
        die "DpxPlugin: manifest disk '$device' (image '$key') missing on disk"
            unless exists $fs_sizes->{$key};
        my $actual = $fs_sizes->{$key};
        die "DpxPlugin: size mismatch for '$device' (manifest=$expected on-disk=$actual)"
            unless $actual == $expected;
        $inv{$key} = { size => $actual + 0 };
    }
    return \%inv;
}

1;
