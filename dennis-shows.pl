#!/usr/bin/env perl

use strict;
use warnings;
use autodie;

my ($action) = @ARGV or die "Usage: $0 mt|umt\n";

my %cfg = (
    share => '//100.91.242.99/PlexMediaServer/TVShows/RecordedTV/',
    mount => '/home/timmccarthey/Public/DennisShows',
    opts  => join(',',
        'credentials=/home/timmccarthey/.cifs-dennis',
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
    if (is_mounted()) {
        print "Already mounted\n";
    } else {
        system('sudo', 'mount', '-t', 'cifs', $cfg{share}, $cfg{mount}, '-o', $cfg{opts});
        is_mounted() ? print "Mounted successfully\n" : warn "Mount failed!\n";
    }
}
elsif ($action eq 'umt') {
    if (!is_mounted()) {
        print "Not mounted\n";
    } else {
        system('sudo', 'umount', $cfg{mount});
        is_mounted() ? warn "Unmount failed!\n" : print "Unmounted successfully\n";
    }
}
else {
    die "Invalid action: use mt or umt\n";
}

