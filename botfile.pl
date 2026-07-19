#!/usr/bin/perl
use strict;
use warnings;
use TMDB;
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Find qw(find);
use File::Basename qw(basename dirname);
use File::Spec;
use JSON::PP qw(decode_json);
use LWP::Simple;

# --- Configuration ---------------------------------------------------------
# Settings are resolved in this order (first non-empty wins):
#   1. environment variables: BOTFILE_API_KEY, BOTFILE_INPUT_DIR,
#      BOTFILE_OUTPUT_DIR, BOTFILE_TV_OUTPUT_DIR
#   2. botfile.conf sitting next to this script ("key = value" lines)
#   3. the built-in defaults in load_config()
# This lets the same script run unchanged whether the libraries are local
# or Synology shares mounted on this machine -- only botfile.conf changes.
my %cfg = load_config();

my $api_key       = $cfg{api_key};
my $input_dir     = $cfg{input_dir};
my $output_dir    = $cfg{output_dir};       # Movies library root
my $tv_output_dir = $cfg{tv_output_dir};    # TV episodes library root

for my $k (qw(api_key input_dir output_dir tv_output_dir)) {
    die "Config error: '$k' is not set (edit botfile.conf next to this script).\n"
        unless defined $cfg{$k} && length $cfg{$k};
}
die "Input directory not found: $input_dir\n" unless -d $input_dir;

# Safety: when the libraries live on NAS mounts, refuse to run if a mount is
# missing -- otherwise matched files would silently pile up on the local disk.
if ($cfg{require_nas_mount}) {
    assert_on_nas_mount($output_dir);
    assert_on_nas_mount($tv_output_dir);
}

# Exclusions / copy history. The excludes file holds one entry per line:
#   - patterns (exact names or globs) for files/dirs to always skip, and
#   - full source paths of files already copied (appended automatically), so
#     re-runs never re-copy the same source ("historic copies").
my $excludes_file = $cfg{excludes_file};
my %exclude_exact;      # full entry strings (e.g. FileBot's NAS-side paths)
my %exclude_base;       # basenames of entries -- matches across machines/mounts
my @exclude_glob;       # compiled regexes for glob patterns (* ?)
load_excludes($excludes_file);

# Initialize TMDB
my $tmdb = TMDB->new(apikey => $api_key);

print "Starting recursive scan of: $input_dir\n";

# Recursively walk the input directory tree
find(
    {
        wanted   => \&process_file,
        no_chdir => 1,
    },
    $input_dir
);

sub process_file {
    my $path     = $File::Find::name;   # full path to the current entry
    my $filename = basename($path);     # basename only (no_chdir sets $_ to full path)

    # Don't descend into excluded directories at all.
    if (-d $path) {
        $File::Find::prune = 1 if is_excluded($path);
        return;
    }

    return if ($filename =~ /^\./);
    return unless -f $path;
    return unless $filename =~ /\.(mkv|avi|mp4|mov)$/i;

    if (is_excluded($path)) {
        print "Skipping (excluded): $path\n";
        return;
    }

    print "\n--- Processing: $path ---\n";

    # Preserve the original file extension for the copied file
    my ($ext) = $filename =~ /\.([^.]+)$/;

    # Route TV episodes and movies down separate paths.
    if (my $tv = parse_tv($filename)) {
        process_tv($path, $ext, $tv);
    } else {
        process_movie($path, $ext, $filename);
    }
}

# Handle a single movie file: search TMDB movies and copy into a Plex
# movie folder.
sub process_movie {
    my ($path, $ext, $filename) = @_;

    # 1. Clean the filename into a search query
    my ($search_query, $search_year) = clean_query($filename);

    unless (length $search_query) {
        print "Skipping: could not derive a title from '$filename'\n";
        return;
    }

    print "Movie search: '$search_query' (Year: "
        . ($search_year || 'any') . ")\n";

    # 2. Query TMDB, preferring a year-constrained search but falling
    #    back to an unconstrained one when nothing comes back.
    my $search = $tmdb->search();
    my @results;
    if ($search_year) {
        @results = $search->movie($search_query, { year => $search_year });
    }
    @results = $search->movie($search_query) unless @results;

    # 3. Pick the best result rather than blindly taking the first.
    my $m = pick_best_match(\@results, $search_query, $search_year);

    if ($m) {
        my $title = $m->{title};
        my $id    = $m->{id};
        my $year  = (defined $m->{release_date} && $m->{release_date} =~ /^(\d{4})/) ? $1 : "0000";

        print "Match Found: $title ($year) [TMDB ID: $id]\n";

        # 4. Folder and Copy logic
        my $safe_title  = sanitize_filename($title);
        my $folder_name = "$safe_title ($year) {tmdb-$id}";
        my $target_dir  = "$output_dir/$folder_name";

        make_path($target_dir) unless -d $target_dir;

        my $dest_file = "$target_dir/$safe_title ($year).$ext";
        print "Copying to: $dest_file\n";

        if (copy($path, $dest_file)) {
            print "Success.\n";
            record_processed($path);   # remember this source so we never re-copy it
            # Download Artwork
            if (my $poster = $m->{poster_path}) {
                getstore("https://image.tmdb.org/t/p/original" . $poster, "$target_dir/folder.jpg");
            }
        }
    } else {
        print "No match found for: '$search_query'\n";
    }
}

# --- Helpers ---------------------------------------------------------------

# Turn a raw video filename into a clean (title, year) search query.
sub clean_query {
    my ($filename) = @_;

    (my $name = $filename) =~ s/\.[^.]+$//;   # drop extension
    $name =~ s/[._]+/ /g;                      # dots/underscores -> spaces
    $name =~ s/\bx\s*26([45])\b/x26$1/gi;      # rejoin x 264 -> x264 after split

    # Extract the year (use the LAST year token; release junk follows it).
    my $search_year = "";
    my @years = $name =~ /\b((?:19|20)\d{2})\b/g;
    if (@years) {
        my $current_year = (localtime)[5] + 1900;
        my $found_valid = 0;
        for my $y (reverse @years) {
            if ($y >= 1888 && $y <= $current_year + 1) {
                $search_year = $y;
                $found_valid = 1;
                last;
            }
        }
        $search_year = $years[-1] unless $found_valid;
        # Everything from the year onward is almost always release metadata.
        $name =~ s/\b\Q$search_year\E\b.*$//;
    }

    # Drop bracketed groups like [YTS.MX], (2020), {edition}.
    $name =~ s/[\[\({][^\]\)}]*[\]\)}]//g;

    # Strip common release / quality / codec / group tags anywhere.
    my @junk = qw(
        2160p 1080p 720p 480p 4k uhd hdr hdr10 dv dolby vision
        webrip web-dl webdl web bluray blu-ray brrip bdrip dvdrip hdtv hdrip cam ts
        x264 x265 h264 h265 hevc avc xvid divx 10bit 8bit
        aac ac3 eac3 dts ddp5 ddp dd5 dd truehd atmos flac mp3 opus 5 1 7
        remux proper repack extended unrated uncut remastered
        directors director's cut theatrical imax multi dual subbed dubbed sub
        yify yts rarbg evo fgt ettv galaxyrg tgx
    );
    my $junk_re = join '|', map { quotemeta } @junk;
    $name =~ s/\b(?:$junk_re)\b//gi;

    # Trailing "-GROUP" release-group suffix. Require the token to be
    # all-uppercase/digits so real hyphenated titles (e.g. "Spider-Verse")
    # are preserved.
    $name =~ s/\s*-\s*[A-Z0-9]{2,}\s*$//;

    # Collapse leftover separators, stray bracket chars, and whitespace.
    $name =~ s/[\[\]\(\)\{\}]//g;
    $name =~ s/[-–—]+/ /g;
    $name =~ s/\s+/ /g;
    $name =~ s/^\s+|\s+$//g;

    return ($name, $search_year);
}

# Normalize a title for comparison: lowercase, alphanumerics only.
sub norm_title {
    my ($t) = @_;
    $t = lc($t // "");
    $t =~ s/&/ and /g;
    $t =~ s/[^a-z0-9]+//g;
    return $t;
}

# Score candidate results and return the best one (or undef).
# $title_key/$date_key let the same scorer handle movies (title/release_date)
# and TV shows (name/first_air_date).
sub pick_best_match {
    my ($results, $query, $year, $title_key, $date_key) = @_;
    return undef unless $results && @$results;
    $title_key ||= 'title';
    $date_key  ||= 'release_date';

    my $nq = norm_title($query);

    my ($best, $best_score);
    for my $i (0 .. $#$results) {
        my $m  = $results->[$i];
        my $nt = norm_title($m->{$title_key});
        my $ry = (defined $m->{$date_key} && $m->{$date_key} =~ /^(\d{4})/) ? $1 : "";

        my $score = 0;
        $score += 100 if $nt eq $nq;                              # exact title
        $score += 40  if $nt ne $nq && ($nt =~ /\Q$nq\E/ || $nq =~ /\Q$nt\E/); # substring
        if ($year && $ry) {
            $score += 50 if $ry eq $year;                        # same year
            $score += 15 if abs($ry - $year) == 1;               # off-by-one
        }
        $score += 10 - $i if $i < 10;                            # TMDB relevance order

        if (!defined $best_score || $score > $best_score) {
            $best_score = $score;
            $best       = $m;
        }
    }
    return $best;
}

# Strip characters that are illegal/awkward in filenames.
sub sanitize_filename {
    my ($s) = @_;
    $s //= "";
    $s =~ s{[/\\:*?"<>|]}{ }g;   # illegal on common filesystems
    $s =~ s/\s+/ /g;
    $s =~ s/^\s+|\s+$//g;
    return $s;
}

# Detect a TV episode from a filename. Returns a hashref
# { show, year, season, episodes => [..] } or undef for non-TV files.
sub parse_tv {
    my ($filename) = @_;

    (my $name = $filename) =~ s/\.[^.]+$//;   # drop extension
    $name =~ s/[._]+/ /g;                      # dots/underscores -> spaces

    my ($season, @eps, $before);

    # SxxExx, with optional multi-episode runs: S01E01E02 or S01E01-E02.
    if ($name =~ /\bS(\d{1,2})[ ._-]?E(\d{1,3})((?:[ ._-]?E\d{1,3})*)/i) {
        $season  = $1 + 0;
        $before  = substr($name, 0, $-[0]);
        push @eps, $2 + 0;
        my $rest = $3 // "";
        while ($rest =~ /E(\d{1,3})/gi) { push @eps, $1 + 0 }
    }
    # 1x02 / 01x02 style.
    elsif ($name =~ /\b(\d{1,2})x(\d{1,3})\b/i) {
        $season = $1 + 0;
        $before = substr($name, 0, $-[0]);
        push @eps, $2 + 0;
    }
    else {
        return undef;
    }

    my ($show, $year) = clean_query($before);
    return undef unless length $show;

    return {
        show     => $show,
        year     => $year,
        season   => $season,
        episodes => \@eps,
    };
}

# Ask TMDB for a single episode's title (best-effort; returns "" on failure).
sub fetch_episode_title {
    my ($tv_id, $season, $episode) = @_;
    my $url = "https://api.themoviedb.org/3/tv/$tv_id/season/$season/episode/"
            . "$episode?api_key=$api_key";
    my $json = get($url) or return "";
    my $data = eval { decode_json($json) };
    return "" unless $data && ref $data eq 'HASH';
    return $data->{name} // "";
}

# Handle a single TV episode file: search TMDB TV, then copy into a Plex
# "Show (Year) {tmdb-ID}/Season NN/Show (Year) - sNNeMM - Title.ext" layout.
sub process_tv {
    my ($path, $ext, $tv) = @_;

    my $show = $tv->{show};
    my $ep_list = join ",", map { sprintf("E%02d", $_) } @{ $tv->{episodes} };
    printf "TV search: '%s' (Year: %s) S%02d %s\n",
        $show, ($tv->{year} || 'any'), $tv->{season}, $ep_list;

    my $search = $tmdb->search();
    my @results;
    if ($tv->{year}) {
        @results = $search->tv($show, { first_air_date_year => $tv->{year} });
    }
    @results = $search->tv($show) unless @results;

    my $m = pick_best_match(\@results, $show, $tv->{year}, 'name', 'first_air_date');
    unless ($m) {
        print "No TV match found for: '$show'\n";
        return;
    }

    my $title = $m->{name} // $m->{original_name};
    my $id    = $m->{id};
    my $year  = (defined $m->{first_air_date} && $m->{first_air_date} =~ /^(\d{4})/)
              ? $1 : "0000";

    print "Match Found: $title ($year) [TMDB ID: $id]\n";

    my $safe_title  = sanitize_filename($title);
    my $show_folder = "$safe_title ($year) {tmdb-$id}";
    my $season_str  = sprintf("%02d", $tv->{season});
    my $season_dir  = "$tv_output_dir/$show_folder/Season $season_str";

    make_path($season_dir) unless -d $season_dir;

    # Episode code: s01e02 (single) or s01e02-e03 (multi-episode file).
    my $ep_code = "s$season_str" . "e"
        . join("-e", map { sprintf("%02d", $_) } @{ $tv->{episodes} });

    # Best-effort episode title (only meaningful for single-episode files).
    my $ep_suffix = "";
    if (@{ $tv->{episodes} } == 1) {
        my $ep_name = fetch_episode_title($id, $tv->{season}, $tv->{episodes}[0]);
        $ep_suffix = " - " . sanitize_filename($ep_name) if length $ep_name;
    }

    my $dest_file = "$season_dir/$safe_title ($year) - $ep_code$ep_suffix.$ext";
    print "Copying to: $dest_file\n";

    if (copy($path, $dest_file)) {
        print "Success.\n";
        record_processed($path);   # remember this source so we never re-copy it
        # Show poster (once per show folder).
        my $poster_dest = "$tv_output_dir/$show_folder/folder.jpg";
        if ((my $poster = $m->{poster_path}) && !-e $poster_dest) {
            getstore("https://image.tmdb.org/t/p/original" . $poster, $poster_dest);
        }
    }
}

# --- Config / environment --------------------------------------------------

# Load settings from env vars, then botfile.conf, then built-in defaults.
sub load_config {
    my %defaults = (
        api_key           => '',    # set in botfile.conf or $BOTFILE_API_KEY
        input_dir         => '/home/timmccarthey/Videos',
        output_dir        => '/home/timmccarthey/Documents',
        tv_output_dir     => '/home/timmccarthey/Documents/TV Shows',
        require_nas_mount => 0,
        excludes_file     => '',    # empty = exclusions/history disabled
    );

    # Locate botfile.conf next to this script, independent of the cwd.
    my $conf = dirname(File::Spec->rel2abs($0)) . '/botfile.conf';
    my %file;
    if (open my $fh, '<', $conf) {
        while (my $line = <$fh>) {
            $line =~ s/#.*$//;                                  # strip comments
            next unless $line =~ /^\s*([A-Za-z_]\w*)\s*=\s*(.*?)\s*$/;
            my ($k, $v) = (lc $1, $2);
            $v =~ s/^["']|["']$//g;                             # optional quotes
            $file{$k} = $v;
        }
        close $fh;
    }

    my %env = (
        api_key       => $ENV{BOTFILE_API_KEY},
        input_dir     => $ENV{BOTFILE_INPUT_DIR},
        output_dir    => $ENV{BOTFILE_OUTPUT_DIR},
        tv_output_dir => $ENV{BOTFILE_TV_OUTPUT_DIR},
        excludes_file => $ENV{BOTFILE_EXCLUDES_FILE},
    );

    my %cfg;
    for my $k (keys %defaults) {
        $cfg{$k} = (defined $env{$k}  && length $env{$k})  ? $env{$k}
                 : (defined $file{$k} && length $file{$k}) ? $file{$k}
                 :                                           $defaults{$k};
    }
    $cfg{require_nas_mount} =
        ($cfg{require_nas_mount} && $cfg{require_nas_mount} !~ /^(0|no|false|off)$/i)
        ? 1 : 0;
    return %cfg;
}

# Confirm $dir lives on a mounted filesystem (i.e. a different device than the
# local root "/"). Guards against the NAS share being unmounted, which would
# otherwise let files copy onto the local disk under an empty mount point.
sub assert_on_nas_mount {
    my ($dir) = @_;

    # The library leaf may not exist yet; walk up to the nearest ancestor
    # that does (that's the mount point itself).
    my $probe = $dir;
    while (!-e $probe) {
        my $parent = dirname($probe);
        last if $parent eq $probe;
        $probe = $parent;
    }

    my @root = stat('/');
    my @tgt  = stat($probe);
    if (@root && @tgt && $root[0] == $tgt[0]) {
        die <<"MSG";
Refusing to run: '$dir' is on the local disk, not a NAS mount.
The Synology share is probably not mounted. Mount it and try again, or set
'require_nas_mount = 0' in botfile.conf to allow sorting into local folders.
MSG
    }
}

# --- Exclusions / copy history ---------------------------------------------

# Read the excludes file into %exclude_exact (literal names/paths) and
# @exclude_glob (compiled regexes for entries containing * or ?). Missing
# file is fine -- it just means nothing is excluded yet.
sub load_excludes {
    my ($file) = @_;
    return unless defined $file && length $file;
    open my $fh, '<', $file or return;   # not yet created is OK
    my $n = 0;
    while (my $line = <$fh>) {
        $line =~ s/\r?\n$//;
        $line =~ s/^\s+|\s+$//g;
        next if $line eq '' || $line =~ /^#/;      # blank / comment
        if ($line =~ /[*?]/) {
            push @exclude_glob, glob_to_regex($line);
        } else {
            $exclude_exact{$line} = 1;
            # Index the basename too, so a FileBot entry recorded as a
            # NAS-side path (/volume1/Torrent/foo.mkv) still matches the same
            # release seen locally (~/Downloads/foo.mkv).
            $exclude_base{ basename($line) } = 1;
        }
        $n++;
    }
    close $fh;
    print "Loaded $n exclusion(s) from $file\n" if $n;
}

# Convert a shell-style glob (only * and ? are special) into a case-
# insensitive anchored regex.
sub glob_to_regex {
    my ($glob) = @_;
    my $re = join '', map {
          $_ eq '*' ? '.*'
        : $_ eq '?' ? '.'
        :             quotemeta($_)
    } split //, $glob;
    return qr/^$re$/i;
}

# True if $path should be skipped: it (or its basename, or any directory
# component) is listed literally, or its basename/full path matches a glob.
sub is_excluded {
    my ($path) = @_;
    return 0 unless %exclude_exact || %exclude_base || @exclude_glob;

    my $base = basename($path);
    return 1 if $exclude_exact{$path} || $exclude_base{$base};

    # Any path segment listed literally (e.g. "Sample", "extras").
    for my $seg (grep { length } split m{/}, $path) {
        return 1 if $exclude_exact{$seg} || $exclude_base{$seg};
    }
    for my $re (@exclude_glob) {
        return 1 if $base =~ $re || $path =~ $re;
    }
    return 0;
}

# Append a successfully-copied source path to the excludes file so future
# runs skip it. Also updates the in-memory set for the current run.
sub record_processed {
    my ($path) = @_;
    $exclude_exact{$path} = 1;
    $exclude_base{ basename($path) } = 1;
    return unless defined $excludes_file && length $excludes_file;
    if (open my $fh, '>>', $excludes_file) {
        print {$fh} "$path\n";
        close $fh;
    } else {
        warn "Could not update excludes file '$excludes_file': $!\n";
    }
}
