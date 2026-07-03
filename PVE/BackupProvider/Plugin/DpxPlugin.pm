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

    # The catalog provisions the per-job token onto the storage config, so the
    # plugin HAS it before job_init and sends it as X-DPX-Job-Token on every
    # backup callback (gateway auth). It no longer relies on job/init to mint one.
    my $job_token = (defined $scfg->{'dpx-job-token'} && length $scfg->{'dpx-job-token'})
        ? $scfg->{'dpx-job-token'}
        : undef;

    return bless {
        scfg        => $scfg,
        storeid     => $storeid,
        log         => $log_function,
        http        => DpxVstor::HttpClient->new(endpoint => $endpoint),
        node_ip     => $node_ip,
        job_token     => $job_token,
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
    }, job_token => $self->{job_token});
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

    my $disks_map = _build_disks_map($self->{disk_stats});

    eval {
        $self->{http}->post('/proxmox/callback/job-done', {
            storeid => $self->{storeid},
            token   => $token,
            disks   => $disks_map,
        }, job_token => $self->{job_token});
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
        my $genid_path = DpxVstor::GenIdSidecar::sidecar_path(
            $storage_path, $vmid, _disk_file_stem($vmid, $device));
        return DpxVstor::GenIdSidecar::read_genid($genid_path);
    };

    my $fetch_modes = sub {
        my ($query) = @_;
        return $self->{http}->get('/proxmox/callback/disk-mode' . $query,
            job_token => $self->{job_token});
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

sub _build_disks_map {
    my ($disk_stats) = @_;
    my %disks_map;
    for my $device (sort keys %{$disk_stats}) {
        my $stat = $disk_stats->{$device} // {};
        $disks_map{$device} = {
            bytesWritten => ($stat->{bytes_written} // 0) + 0,
            fileSize     => ($stat->{file_size} // 0) + 0,
        };
    }
    return \%disks_map;
}

sub _uri_escape {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/([^A-Za-z0-9_.~-])/sprintf('%%%02X', ord($1))/ge;
    return $value;
}

# QEMU/QMP hands us its own internal block-device id (e.g. "drive-scsi0") as
# the device key for backup_vm/backup_vm_query_incremental and echoes the same
# string back via restore_vm_volume_init's $device_name. That literal value is
# load-bearing on the wire: it doubles as the NBD export name during backup
# (must match what QEMU created) and, via the "#qmdump#map" line embedded in
# vm_config by the catalog, is looked up verbatim by PVE's own restore code to
# resolve which guest disk slot a restored volume belongs to. It is NOT,
# however, load-bearing for OUR OWN storage-layer file/sidecar naming, which is
# purely a local implementation detail. Strip the QEMU-internal "drive-"
# prefix only when deriving our own on-disk stem, never when talking to PVE or
# posting the "device" field back to the catalog.
sub _drive_file_stem {
    my ($device) = @_;
    return $device unless defined $device;
    $device =~ s/^drive-//;
    return $device;
}

# On-disk filenames mirror PVE's own native volume-naming shape
# (vm-<vmid>-disk-<n>.raw) instead of the bus/slot name. The index <n> is the
# trailing digit run of the slot itself (scsi0 -> 0, virtio3 -> 3, sata1 -> 1)
# -- NOT an allocation-order counter and NOT derived from how many disks
# currently exist on the VM. PVE assigns that slot number to the guest and
# keeps it stable for the disk's whole life, so deriving the index purely
# from it means a given disk's filename never changes across backup runs
# regardless of whether OTHER disks on the VM are added or removed later: no
# renumbering, no dependency on write order.
#
# Caveat: mixed bus types can collide on the same trailing digit (scsi0 and
# virtio0 both resolve to index 0). Unlike the old <slot>.raw scheme -- where
# the bus-type letters were part of the filename and collisions were
# impossible -- callers that process multiple devices for one VM in a single
# pass MUST guard against this (see the %assigned_index check in backup_vm).
sub _disk_index {
    my ($device) = @_;
    my $slot = _drive_file_stem($device);
    my ($idx) = ($slot =~ /(\d+)\s*$/)
        or die "DpxPlugin: cannot derive disk index from device '$device' (slot '$slot')";
    return $idx;
}

sub _disk_file_stem {
    my ($vmid, $device) = @_;
    return "vm-${vmid}-disk-" . _disk_index($device);
}

sub backup_handle_log_file {
    my ($self, $vmid, $log) = @_;
    return undef;
}

# Parses the raw text of qemu-server/<vmid>.conf and returns a { slot => volid }
# map for disk-bus lines (scsiN/virtioN/ideN/sataN). A matching line looks like
# "scsi0: local-lvm:vm-100-disk-0,size=32G" — the volid is everything between
# the first ":" and the first "," (or end of line). Lines whose value is the
# literal "none" (e.g. an empty ide cdrom: "ide2: none,media=cdrom") yield no
# volid for that slot. Non-disk-bus lines (net0, etc.) are ignored.
sub _parse_volid_by_slot {
    my ($guest_config) = @_;
    my %volid_by_slot;
    return \%volid_by_slot unless defined $guest_config;

    for my $line (split /\n/, $guest_config) {
        if ($line =~ /^\s*((?:scsi|virtio|ide|sata)\d+)\s*:\s*([^,]*)/) {
            my ($slot, $value) = ($1, $2);
            $value =~ s/\s+$//;
            $volid_by_slot{$slot} = ($value eq 'none' || $value eq '') ? undef : $value;
        }
    }
    return \%volid_by_slot;
}

sub backup_vm {
    my ($self, $vmid, $guest_config, $volumes, $info) = @_;
    my $token = $self->{job_token}
        or die "DpxPlugin: backup_vm called without job_token (job_init not called?)";

    my %volid_by_slot = %{ _parse_volid_by_slot($guest_config) };

    # Tracks which disk index each device has claimed so far in this
    # backup_vm call. Index-only naming (vm-<vmid>-disk-<n>.raw) can collide
    # across bus types (scsi0 and virtio0 both -> index 0); the old
    # <slot>.raw scheme couldn't, since the bus letters were part of the
    # filename. Fail loudly rather than let one disk's backup silently
    # overwrite the other's file.
    my %assigned_index;

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

        my $storage_path = $self->{scfg}{path}
            or die "DpxPlugin: no path in scfg (NFS not mounted?)";
        my $slot          = _drive_file_stem($device);
        my $source_volid  = $volid_by_slot{$slot};

        my $disk_index = _disk_index($device);
        if (exists $assigned_index{$disk_index} && $assigned_index{$disk_index} ne $device) {
            die sprintf(
                "DpxPlugin: disk index collision for vmid=%s: devices '%s' and '%s' "
              . "both resolve to disk index %s (filename vm-%s-disk-%s.raw); refusing "
              . "to overwrite",
                $vmid, $assigned_index{$disk_index}, $device, $disk_index, $vmid, $disk_index);
        }
        $assigned_index{$disk_index} = $device;

        my $file_stem = _disk_file_stem($vmid, $device);

        $self->_log('info', sprintf(
            "DpxPlugin: backup_vm vmid=%s device=%s size=%s bitmap-mode=%s bitmap=%s action=%s source_volid=%s",
            $vmid, $device, $size_bytes, $bitmap_mode, $bitmap_name, $transfer_action,
            ($source_volid // 'undef')));

        my $target_dir  = "$storage_path/vm-$vmid";
        my $target_path = "$target_dir/$file_stem.raw";

        make_path($target_dir) unless -d $target_dir;

        my $genid_path = DpxVstor::GenIdSidecar::sidecar_path(
            $storage_path, $vmid, $file_stem);
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
                sourceVolid   => $source_volid,
            }, job_token => $self->{job_token});
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
            $bytes_written = $transfer_summary->{bytes_written} // 0;
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
            }, job_token => $self->{job_token});
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

        $self->{disk_stats}{$device} = {
            bytes_written => $bytes_written,
            file_size     => $file_size,
        };
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
        volname             => $volname,
        pve_node_ip         => $self->{node_ip},
        storeid             => $self->{storeid},
        'dpx-restore-token' => $self->{scfg}{'dpx-restore-token'},
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
        my @entries = readdir($dh);
        closedir $dh;
        for my $entry (@entries) {
            next unless $entry =~ /^(.+)\.raw$/;
            my $device = $1;
            my @st = stat("$vm_dir/$entry") or next;
            my ($sz) = ($st[7] =~ /^(\d+)$/)
                or die "DpxPlugin: bad size for $entry";
            $fs_sizes{$device} = $sz;
        }
    }

    my $inv = _reconcile_inventory($source_vmid, $resp->{disks}, \%fs_sizes);

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
    my $raw_path = "$storage_path/vm-$vmid/" . _disk_file_stem($vmid, $safe_device) . '.raw';

    die "DpxPlugin: image not found at $raw_path" unless -f $raw_path;

    $self->_log('info', "DpxPlugin: restore_vm_volume_init device=$device_name path=$raw_path");
    return { 'qemu-img-path' => $raw_path };
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
    my ($vmid, $manifest_disks, $fs_sizes) = @_;
    my %inv;
    for my $disk (@{$manifest_disks // []}) {
        my $device = $disk->{device};
        my $expected = $disk->{size_bytes} // $disk->{sizeBytes};
        die "DpxPlugin: manifest disk missing device name"
            unless defined $device;
        die "DpxPlugin: manifest disk '$device' missing size"
            unless defined $expected;
        # $key is what we hand back to PVE as the restore inventory key; PVE
        # echoes it back unchanged via restore_vm_volume_init and also matches
        # it verbatim against the "#qmdump#map" devname baked into vm_config,
        # so it MUST stay whatever the manifest gave us (drive-prefixed or
        # not). Our own on-disk filename is a separate, local concern: it is
        # derived forward from the device string via _disk_file_stem, exactly
        # symmetric with the write path in backup_vm — no need to
        # reverse-engineer bus type from a bare numeric filename.
        my $key = (defined $disk->{image_name} && length $disk->{image_name})
            ? $disk->{image_name}
            : $device;
        my $file_stem = _disk_file_stem($vmid, $key);
        die "DpxPlugin: manifest disk '$device' (image '$key') missing on disk"
            unless exists $fs_sizes->{$file_stem};
        my $actual = $fs_sizes->{$file_stem};
        die "DpxPlugin: size mismatch for '$device' (manifest=$expected on-disk=$actual)"
            unless $actual == $expected;
        $inv{$key} = { size => $actual + 0 };
    }
    return \%inv;
}

1;
