#!/usr/bin/env perl

use strict;
use warnings;
use autodie;
use LWP::UserAgent;
use JSON;

# Configuration for all shares
my %shares = (
    'dennis-movies' => {
        share => '//100.91.242.99/PlexMediaServer/Movies/DVD',
        mount => '/home/timmccarthey/Public/DennisMovies',
        creds => '/home/timmccarthey/.cifs-dennis',
    },
    'dennis-shows' => {
        share => '//100.91.242.99/PlexMediaServer/TVShows/RecordedTV/',
        mount => '/home/timmccarthey/Public/DennisShows',
        creds => '/home/timmccarthey/.cifs-dennis',
    },
    'mike-movies' => {
        share => '//100.124.129.63/Movies/DVD',
        mount => '/home/timmccarthey/Public/MikeMovies',
        creds => '/home/timmccarthey/.cifs-mike',
    },
    'mike-shows' => {
        share => '//100.124.129.63/TVshows/RecordedTV',
        mount => '/home/timmccarthey/Public/MikeShows',
        creds => '/home/timmccarthey/.cifs-mike',
    },
    'mom-movies' => {
        share => '//100.123.16.36/Movies/DVD',
        mount => '/home/timmccarthey/Public/MomMovies',
        creds => '/home/timmccarthey/.cifs-mom',
    },
    'mom-shows' => {
        share => '//100.123.16.36/TVShows/RecordedTV',
        mount => '/home/timmccarthey/Public/MomShows',
        creds => '/home/timmccarthey/.cifs-mom',
    },
    'tim-movies' => {
        share => '//192.168.1.99/docker/Plex/Movies/DVD',
        mount => '/home/timmccarthey/Public/TimMovies',
        creds => '/home/timmccarthey/.cifs-tim',
    },
    'tim-shows' => {
        share => '//192.168.1.99/docker/Plex/Shows/RecordedTV',
        mount => '/home/timmccarthey/Public/TimShows',
        creds => '/home/timmccarthey/.cifs-tim',
    },
);

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

sub mount_share {
    my ($name) = @_;
    my $cfg = $shares{$name} or die "Unknown share: $name\n";

    if (is_mounted($cfg->{mount})) {
        print "Already mounted: $name\n";
        return;
    }

    my $opts = $mount_opts_template;
    $opts =~ s/CREDS/$cfg->{creds}/;

    system('sudo', 'mount', '-t', 'cifs',
           $cfg->{share}, $cfg->{mount},
           '-o', $opts);

    print "Mounted: $name\n" if is_mounted($cfg->{mount});
}

sub unmount_share {
    my ($name) = @_;
    my $cfg = $shares{$name} or die "Unknown share: $name\n";

    if (!is_mounted($cfg->{mount})) {
        print "Not mounted: $name\n";
        return;
    }

    system('sudo', 'umount', $cfg->{mount});
    print "Unmounted: $name\n" unless is_mounted($cfg->{mount});
}

sub tmdb_search {
    my ($movie_title) = @_;

    my $api_key = $ENV{TMDB_API_KEY};
    unless ($api_key) {
        my $key_file = "$ENV{HOME}/.tmdb-api-key";
        open(my $fh, '<', $key_file) or die "No TMDB_API_KEY env var and cannot read $key_file: $!\n";
        chomp($api_key = <$fh>);
        close($fh);
    }
    $movie_title =~ s/ /%20/g;

    my $ua = LWP::UserAgent->new;

    # Search for the movie
    my $search_url = "https://api.themoviedb.org/3/search/movie?api_key=$api_key&query=$movie_title";
    my $search_response = $ua->get($search_url);

    die "Search failed: " . $search_response->status_line unless $search_response->is_success;

    my $search_result = decode_json($search_response->decoded_content);
    my $movie = $search_result->{results}[0] or die "No results found.\n";

    my $movie_id = $movie->{id};
    print "Found Movie: $movie->{title} (ID: $movie_id)\n";

    # Get detailed info
    my $details_url = "https://api.themoviedb.org/3/movie/$movie_id?api_key=$api_key";
    my $details_response = $ua->get($details_url);

    die "Details request failed: " . $details_response->status_line unless $details_response->is_success;

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

sub show_usage {
    print "Usage: $0 <command> [options]\n\n";
    print "Commands:\n";
    print "  mt <share>      Mount a share\n";
    print "  umt <share>     Unmount a share\n";
    print "  mt-all          Mount all shares\n";
    print "  umt-all         Unmount all shares\n";
    print "  list            List all available shares\n";
    print "  status          Show mount status of all shares\n";
    print "  tmdb <title>    Search for movie on TMDb\n\n";
    print "Available shares:\n";
    print "  " . join(', ', sort keys %shares) . "\n";
    exit 1;
}

# Main logic
my ($command, @args) = @ARGV;

show_usage() unless $command;

if ($command eq 'mt') {
    my $share = $args[0] or die "Usage: $0 mt <share>\n";
    mount_share($share);
}
elsif ($command eq 'umt') {
    my $share = $args[0] or die "Usage: $0 umt <share>\n";
    unmount_share($share);
}
elsif ($command eq 'mt-all') {
    mount_share($_) for sort keys %shares;
}
elsif ($command eq 'umt-all') {
    unmount_share($_) for sort keys %shares;
}
elsif ($command eq 'list') {
    print "Available shares:\n";
    print "  $_\n" for sort keys %shares;
}
elsif ($command eq 'status') {
    print "Mount status:\n";
    for my $name (sort keys %shares) {
        my $mounted = is_mounted($shares{$name}{mount}) ? 'MOUNTED' : 'not mounted';
        printf "  %-15s : %s\n", $name, $mounted;
    }
}
elsif ($command eq 'tmdb') {
    my $title = join(' ', @args) or die "Usage: $0 tmdb <movie title>\n";
    tmdb_search($title);
}
else {
    die "Unknown command: $command\n\n";
}
