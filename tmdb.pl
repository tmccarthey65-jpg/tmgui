#!/usr/bin/env perl
use strict;
use warnings;
use LWP::UserAgent;
use JSON;
use URI::Escape;

my $movie_title = join(' ', @ARGV) or die "Usage: $0 <movie title>\n";

my $api_key = $ENV{TMDB_API_KEY};
unless ($api_key) {
    my $key_file = "$ENV{HOME}/.tmdb-api-key";
    open(my $fh, '<', $key_file) or die "No TMDB_API_KEY env var and cannot read $key_file: $!\n";
    chomp($api_key = <$fh>);
    close($fh);
}

my $ua = LWP::UserAgent->new;

# Step 1: Search for the movie to get its ID
my $search_url = "https://api.themoviedb.org/3/search/movie?api_key=$api_key&query=" . uri_escape($movie_title);
my $search_response = $ua->get($search_url);

die "Search failed: " . $search_response->status_line unless $search_response->is_success;

my $search_result = decode_json($search_response->decoded_content);
my $movie = $search_result->{results}[0] or die "No results found.\n";

my $movie_id = $movie->{id};
print "Found Movie: $movie->{title} (ID: $movie_id)\n";

# Step 2: Get detailed movie info
my $details_url = "https://api.themoviedb.org/3/movie/$movie_id?api_key=$api_key";
my $details_response = $ua->get($details_url);

die "Details request failed: " . $details_response->status_line unless $details_response->is_success;

my $details = decode_json($details_response->decoded_content);

my $title        = $details->{title};
my $release_date = $details->{release_date};
my $overview     = $details->{overview};
my @genres       = map { $_->{name} } @{$details->{genres}};

print "\n";
print "Title       : $title\n";
print "Release Date: $release_date\n";
print "Genres      : " . join(', ', @genres) . "\n";
print "First Level : $genres[0]\n" if @genres;
print "Overview    :\n$overview\n";
