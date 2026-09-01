# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Catalogic Software, Inc.
use strict; use warnings; use Test::More;
use File::Find;

# PVE::BackupProvider::Plugin::Base documents the levels as "Either info, warn
# or err", and PVE::VZDump::Plugin::debugmsg silently coerces anything else to
# 'err' -- so a level typo prints routine progress as "ERROR:" in the Task
# Viewer instead of failing loudly. A pure source scan, so this file needs no
# PVE stubs and passes in the public repo on its own.
my %ALLOWED = map { $_ => 1 } qw(info warn err);

my @sources;
find(sub { push @sources, $File::Find::name if /\.pm$/ }, 'PVE');
plan tests => scalar @sources;

for my $file (sort @sources) {
    open(my $fh, '<', $file) or die "cannot read $file: $!";
    my @bad;
    my $lineno = 0;
    while (my $line = <$fh>) {
        $lineno++;
        # Matches both $log->('level', ...) and $self->_log('level', ...).
        while ($line =~ /(?:->|_log)\s*\(\s*'([a-z]+)'\s*,/g) {
            push @bad, "$file:$lineno uses level '$1'" unless $ALLOWED{$1};
        }
    }
    close($fh);
    is_deeply(\@bad, [], "$file logs only at info/warn/err");
}
