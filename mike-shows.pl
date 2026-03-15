#!/usr/bin/env perl

use strict;
use warnings;
use autodie;

my ($action) = @ARGV or die "Usage: $0 mt|umt\n";

my %cfg = (
    share => '//REDACTED/TVshows/RecordedTV',
    mount => '/home/timmccarthey/Public/MikeShows',
    opts  => join(',',
        'credentials=/home/timmccarthey/.cifs-mike',
        'iocharset=utf8',
        'file_mode=0777',
        'dir_mode=0777',
        'soft',
        'noperm',
    ),
);

sub is_mounted {
    system('mountpoint', '-q', $cfg{mount}) == 0;
}

if ($action eq 'mt') {
    is_mounted()
        ? print "Already mounted\n"
        : system('sudo', 'mount', '-t', 'cifs',
                 $cfg{share}, $cfg{mount},
                 '-o', $cfg{opts});
}
elsif ($action eq 'umt') {
    is_mounted()
        ? system('sudo', 'umount', $cfg{mount})
        : print "Not mounted\n";
}
else {
    die "Invalid action: use mt or umt\n";
}

