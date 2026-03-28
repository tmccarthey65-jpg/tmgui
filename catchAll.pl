#!/usr/bin/env perl

use strict;
use warnings;
use autodie;
use LWP::UserAgent;
use JSON;
use URI::Escape;

use File::Slurp;

# Configuration for all shares
my $json_text = read_file('/home/timmccarthey/Public/shares.json');
my $shares_ref = decode_json($json_text);
my %shares = %{$shares_ref};


# Common mount options template
my $mount_opts_template = join(',',
    'credentials=CREDS',
    'iocharset=utf8',
    'file_mode=0777',
    'dir_mode=0777',
    'soft',
    'noperm',
);

sub is_mounted {
    my ($mount_point) = @_;
    system('mountpoint', '-q', $mount_point) == 0;
}

use IPC::System::Simple qw(capture);

sub mount_share {
    my ($name) = @_;
    my $cfg = $shares{$name} or die "Unknown share: $name\n";

    if (is_mounted($cfg->{mount})) {
        print "Already mounted: $name\n";
        return;
    }

    my $opts = $mount_opts_template;
    $opts =~ s/CREDS/$cfg->{creds}/;

    my $output = capture('sudo', 'mount', '-t', 'cifs',
           $cfg->{share}, $cfg->{mount},
           '-o', $opts);

    if (is_mounted($cfg->{mount})) {
        print "Mounted: $name\n";
    } else {
        warn "Mount failed: $name\n";
        warn "Reason: $output\n" if $output;
    }
}

sub unmount_share {
    my ($name) = @_;
    my $cfg = $shares{$name} or die "Unknown share: $name\n";

    if (!is_mounted($cfg->{mount})) {
        print "Not mounted: $name\n";
        return;
    }

    my $output;
    my $max_retries = 3;
    for my $attempt (1 .. $max_retries) {
        $output = eval { capture('sudo', 'umount', $cfg->{mount}) };
        last unless is_mounted($cfg->{mount});
        if ($attempt < $max_retries) {
            print "Unmount busy, retrying ($attempt/$max_retries)...\n";
            sleep 3;
        }
    }

    if (is_mounted($cfg->{mount})) {
        print "Share busy, attempting lazy unmount: $name\n";
        eval { capture('sudo', 'umount', '-l', $cfg->{mount}) };
        if (is_mounted($cfg->{mount})) {
            warn "Failed to unmount: $name\n";
        } else {
            print "Lazy unmounted: $name\n";
        }
    } else {
        print "Unmounted: $name\n";
    }
}

sub tmdb_search {
    my ($movie_title) = @_;

    my $api_key = $ENV{TMDB_API_KEY};
    unless ($api_key) {
        my $key_file = "$ENV{HOME}/.tmdb-api-key";
        if (-e $key_file) {
            open(my $fh, '<', $key_file) or die "Cannot read $key_file: $!\n";
            chomp($api_key = <$fh>);
            close($fh);
        } else {
            print "Error: TMDB_API_KEY environment variable not set and .tmdb-api-key file not found.\n";
            exit 1;
        }
    }
    $movie_title = uri_escape($movie_title);

    my $ua = LWP::UserAgent->new;

    # Search for the movie
    my $search_url = "https://api.themoviedb.org/3/search/movie?api_key=$api_key&query=$movie_title";
    my $search_response = $ua->get($search_url);

    unless ($search_response->is_success) {
        print "Error: Search failed: " . $search_response->status_line . "\n";
        return;
    }

    my $search_result = decode_json($search_response->decoded_content);
    unless (@{$search_result->{results}}) {
        print "No results found for '$movie_title'.\n";
        return;
    }
    my $movie = $search_result->{results}[0];

    my $movie_id = $movie->{id};
    print "Found Movie: $movie->{title} (ID: $movie_id)\n";

    # Get detailed info
    my $details_url = "https://api.themoviedb.org/3/movie/$movie_id?api_key=$api_key";
    my $details_response = $ua->get($details_url);

    unless ($details_response->is_success) {
        print "Error: Details request failed: " . $details_response->status_line . "\n";
        return;
    }

    my $details = decode_json($details_response->decoded_content);

    my $title = $details->{title};
    my $release_date = $details->{release_date};
    my $overview = $details->{overview};
    my @genres = map { $_->{name} } @{$details->{genres}};

    print "\n";
    print "Title       : $title\n";
    print "Release Date: $release_date\n";
    print "Genres      : " . join(', ', @genres) . "\n";
    print "First Level : $genres[0]\n" if @genres;
    print "Overview    :\n$overview\n";
}

use Getopt::Long qw(GetOptions);

sub show_usage {
    print "Usage: $0 <command> [options]\n\n";
    print "Commands:\n";
    print "  --mount <share>      Mount a share\n";
    print "  --unmount <share>    Unmount a share\n";
    print "  --mount-all          Mount all shares\n";
    print "  --unmount-all        Unmount all shares\n";
    print "  --list               List all available shares\n";
    print "  --status             Show mount status of all shares\n";
    print "  --tmdb <title>       Search for movie on TMDb\n";
    print "  --help               Show this help message\n\n";
    print "Available shares:\n";
    print "  " . join(', ', sort keys %shares) . "\n";
    exit 1;
}

# Main logic
my %opts;
GetOptions(
    'mount|mt=s'       => \$opts{mount},
    'unmount|umt=s'     => \$opts{unmount},
    'mount-all|mt-all'   => \$opts{mount_all},
    'unmount-all|umt-all' => \$opts{unmount_all},
    'list'          => \$opts{list},
    'status'        => \$opts{status},
    'tmdb=s'        => \$opts{tmdb},
    'help'          => \$opts{help},
) or show_usage();

show_usage() if $opts{help} || !%opts;

if (my $share = $opts{mount}) {
    mount_share($share);
}
elsif (my $share_to_unmount = $opts{unmount}) {
    unmount_share($share_to_unmount);
}
elsif ($opts{mount_all}) {
    mount_share($_) for sort keys %shares;
}
elsif ($opts{unmount_all}) {
    unmount_share($_) for sort keys %shares;
}
elsif ($opts{list}) {
    print "Available shares:\n";
    print "  $_\n" for sort keys %shares;
}
elsif ($opts{status}) {
    print "Mount status:\n";
    for my $name (sort keys %shares) {
        my $mounted = is_mounted($shares{$name}{mount}) ? 'MOUNTED' : 'not mounted';
        printf "  %-15s : %s\n", $name, $mounted;
    }
}
elsif (my $title = $opts{tmdb}) {
    tmdb_search($title);
}
else {
    print "Unknown command or missing argument.\n\n";
    show_usage();
}
