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

    # Ask the catalog which disks must run full. The catalog folds in the
    # version-gate, the durable force-full/remediation flag, AND baseline-genId
    # divergence. Returning PVE 'new' here makes QEMU create a FRESH bitmap and
    # stream a full for that disk — the force-full and the bitmap reset happen
    # together, so the next run starts a clean incremental chain. 'use' lets PVE
    # reuse the existing bitmap (incremental). On any failure we fail safe to
    # 'new' (full) rather than risk overlaying onto a diverged base.
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

        # Determine target path: under the NFS-mounted storage path
        # NFSPlugin mounts at $scfg->{path}; images go in vm-<vmid>/
        my $storage_path = $self->{scfg}{path}
            or die "DpxPlugin: no path in scfg (NFS not mounted?)";
        my $target_dir  = "$storage_path/vm-$vmid";
        my $target_path = "$target_dir/$device.img";

        make_path($target_dir) unless -d $target_dir;

        my $genid_path = DpxVstor::GenIdSidecar::sidecar_path(
            $storage_path, $vmid, $device);
        my $baseline_genid = DpxVstor::GenIdSidecar::read_genid($genid_path);

        # Tell catalog this disk is starting; the response carries a genId
        # (a fresh UUID on a base run, the echoed baseline on an incremental)
        # and an action ('base'/'incremental'). action='base' is the catalog's
        # force-full verdict (version-gate / force-full flag / genId divergence).
        # Path A normally resets the bitmap at query_incremental so PVE already
        # hands us bitmap_mode!='reuse' here; this is the data-path backstop for
        # the case where the 'new' verdict did not reach QEMU. We override to a
        # full rebuild but DO NOT touch the QEMU bitmap (that was handled at
        # query_incremental) — we only refuse to overlay onto a diverged base.
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

        # Capture the pre-overlay allocation of the existing target image for a
        # reuse/overlay incremental. This becomes the integrity-gate floor:
        # a legitimate incremental keeps at least (pre_overlay - punched_zero)
        # allocated, so a collapsed-shell overlay (correct logical size but
        # near-zero allocation) is detected. For a base run there is nothing to
        # collapse from, so the floor stays 0.
        my $pre_overlay_alloc = ($effective_bitmap_mode eq 'reuse' && -e $target_path)
            ? DpxVstor::IntegrityGate::allocated_bytes($target_path)
            : 0;

        # Perform data transfer directly via UNIX socket
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
            # Get written size from file
            $bytes_written = -s $target_path // 0;
        };
        if ($@) {
            die "DpxPlugin: NbdTransfer failed for $device: $@";
        }

        # Post-fsync integrity gate: verify the just-written live image and
        # report the result so the catalog can refuse the snapshot if it fails.
        # For a reuse/overlay incremental we pass the pre-overlay allocation as
        # the floor so a collapsed-shell write (correct logical size, near-zero
        # allocation) is caught. For a base run the floor is 0.
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
        # If this POST is swallowed (transient HTTP failure / crash), the
        # catalog receives no integrity result for this disk and FAILS CLOSED
        # (ProxmoxBackupRunner.runVm requires a passed result for every
        # transferred disk). We therefore do not die here on a POST failure;
        # we only warn so the missing-result path stays the single source of
        # truth for correctness.
        $self->_log('warn',
            "DpxPlugin: integrity-result POST failed for $device (catalog will "
          . "fail closed on the missing result): $@") if $@;
        die "DpxPlugin: integrity gate FAILED for $device: $integ->{message}"
            unless $integ->{passed};

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
    $self->_log('info', "DpxPlugin: restore_vm_init volname=$volname");

    my $resp = $self->{http}->post('/proxmox/restore/init', {
        volname     => $volname,
        pve_node_ip => $self->{node_ip},
    });

    my $session_id = $resp->{session_id}
        or die "DpxPlugin: no session_id in /proxmox/restore/init response";

    $self->{restore_session_id} = $session_id;
    $self->{restore_volname}    = $volname;

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
    # Guest config is stored as vm-config.json in the backup directory
    my $vmid = $self->{restore_source_vmid};
    return undef unless defined $vmid;

    my $storage_path = $self->{scfg}{path} // '';
    my $config_path  = "$storage_path/vm-$vmid/vm-config.json";
    return undef unless -r $config_path;

    open(my $fh, '<', $config_path) or return undef;
    local $/;
    my $raw = <$fh>;
    close $fh;

    my $parsed = eval { decode_json($raw) };
    return undef if $@;

    if (ref($parsed) eq 'HASH' && exists $parsed->{vmConfig}) {
        my $cfg = $parsed->{vmConfig};
        return ref($cfg) ? encode_json($cfg) : $cfg;
    }
    return $raw;
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
    # Strip storage prefix and archive extension
    my $bare = $volname;
    $bare =~ s{^[^:]+:backup/}{};
    $bare =~ s{\.vma(?:\..+)?$}{};
    # Expected: snap-<snapshotId>-vm-<vmid>
    if ($bare =~ /-vm-(\d+)$/) {
        return $1;
    }
    die "DpxPlugin: cannot parse vmid from volname '$volname'";
}

1;
