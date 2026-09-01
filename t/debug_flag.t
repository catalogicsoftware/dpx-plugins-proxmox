# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Catalogic Software, Inc.
use strict;
use warnings;
use Test::More tests => 11;
use File::Temp qw(tempdir);

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

my $dir = tempdir(CLEANUP => 1);
my $n = 0;

sub flag_for {
    my ($contents) = @_;
    my $path = "$dir/conf" . $n++;
    open(my $fh, '>', $path) or die "cannot write $path: $!";
    print $fh $contents;
    close($fh);
    return PVE::BackupProvider::Plugin::DpxPlugin::_read_debug_flag($path);
}

# Off is the default, and must stay off for anything that is not an explicit
# affirmative: leaving tracing on by accident floods /var/log/pve/tasks.
is(PVE::BackupProvider::Plugin::DpxPlugin::_read_debug_flag("$dir/does-not-exist"), 0,
    'missing file means off');
is(flag_for(''),               0, 'empty file means off');
is(flag_for("debug: 0\n"),     0, 'explicit 0 means off');
is(flag_for("# debug: 1\n"),   0, 'commented-out line means off');
is(flag_for("verbose: 1\n"),   0, 'unrelated key means off');
is(flag_for("debug: maybe\n"), 0, 'unrecognised value means off');

is(flag_for("debug: 1\n"),      1, 'debug: 1 turns it on');
is(flag_for("debug=true\n"),    1, 'equals form and true are accepted');
is(flag_for("  debug : YES\n"), 1, 'whitespace and case are tolerated');
is(flag_for("debug: 1\ndebug: 0\n"), 0, 'last key wins');

# A directory (or any unopenable path) must degrade to off rather than die: a
# broken config file must never be able to fail a backup.
is(PVE::BackupProvider::Plugin::DpxPlugin::_read_debug_flag($dir), 0,
    'unopenable path means off and does not die');
