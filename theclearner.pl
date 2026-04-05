#!/usr/bin/perl
use strict;
use warnings;
use File::Find;
use File::Path qw(rmtree);

die "Usage: $0 <path>\n" unless @ARGV == 1;

my $root = $ARGV[0];
die "Path '$root' does not exist.\n" unless -d $root;

# Collect empty directories bottom-up
my @empty_dirs;

find({
    bydepth => 1,
    wanted  => sub {
        my $dir = $File::Find::name;
        return unless -d $dir;
        return if $dir eq $root;

        opendir(my $dh, $dir) or return;
        my @entries = grep { $_ ne '.' && $_ ne '..' } readdir($dh);
        closedir($dh);

        push @empty_dirs, $dir if @entries == 0;
    },
}, $root);

unless (@empty_dirs) {
    print "No empty folders found under '$root'.\n";
    exit 0;
}

print "Found " . scalar(@empty_dirs) . " empty folder(s):\n\n";
for my $dir (@empty_dirs) {
    print "  $dir\n";
}
print "\n";

my $yes_to_all = 0;

for my $dir (@empty_dirs) {
    if (!$yes_to_all) {
        print "Remove: $dir\n";
        print "  Delete? [y/n/a(ll)]: ";
        chomp(my $answer = <STDIN>);
        if (lc($answer) eq 'a') {
            $yes_to_all = 1;
        } elsif (lc($answer) ne 'y') {
            print "  Skipped.\n";
            next;
        }
    }

    print "  Removing: $dir ... ";
    if (rmdir($dir)) {
        print "done.\n";
    } else {
        print "FAILED: $!\n";
    }
}

print "\nDone.\n";
