#!/usr/bin/perl

use strict;
use warnings;
use Tk;
use File::Basename;
use File::Spec;
use File::Path qw(make_path);
use File::Find;
use JSON;

$| = 1; # Disable output buffering

# Single-instance enforcement via PID lock file
my $LOCK_FILE = '/tmp/plex_storage_copier.lock';

if (-e $LOCK_FILE) {
    open(my $lf, '<', $LOCK_FILE) or die "Cannot read lock file: $!";
    my $pid = <$lf>;
    close($lf);
    chomp $pid if defined $pid;

    if (defined $pid && $pid =~ /^\d+$/ && kill(0, $pid)) {
        # Another instance is running — show a Tk error dialog then exit
        my $tmp = MainWindow->new;
        $tmp->withdraw;
        $tmp->messageBox(
            -title   => 'Already Running',
            -message => "Plex Storage Copier is already running (PID $pid).\nOnly one instance is allowed.",
            -type    => 'OK',
            -icon    => 'error',
        );
        $tmp->destroy;
        exit 1;
    }
    # Stale lock file — remove it
    unlink $LOCK_FILE;
}

# Write our PID to the lock file
open(my $lf, '>', $LOCK_FILE) or die "Cannot create lock file: $!";
print $lf $$;
close($lf);

END { unlink $LOCK_FILE if -e $LOCK_FILE }

# ---------------------------------------------------------------------------
# Styling and Theme Configuration (Dark Theme)
# ---------------------------------------------------------------------------
my $C_BG          = '#151522';   # Main window background
my $C_PANEL       = '#1D1D2C';   # Cards/Panel background
my $C_BORDER      = '#31314B';   # Separators
my $C_TEXT        = '#E2E2EC';   # Primary text
my $C_SUBTEXT     = '#8E8E9F';   # Dimmed text

my $C_HDR_LOCAL   = '#1A6BB5';   # Movies Active Blue
my $C_HDR_REMOTE  = '#A0303A';   # Shows Active Red/Maroon
my $C_HDR_FG      = '#FFFFFF';   # White header text

my $C_BTN_BG      = '#252538';   # Default button background
my $C_BTN_FG      = '#B0B0C4';   # Default button text
my $C_BTN_ACT     = '#363654';   # Button active/hover state

my $C_SEL_BG      = '#2D7DD2';   # Listbox selection background
my $C_SEL_FG      = '#FFFFFF';   # Listbox selection text

# Font Family Definitions
my $F_TITLE       = ['Helvetica', 14, 'bold'];
my $F_HEADER      = ['Helvetica', 12, 'bold'];
my $F_BOLD        = ['Helvetica', 10, 'bold'];
my $F_NORMAL      = ['Helvetica', 10];
my $F_MONO        = ['Courier', 10];
my $F_SMALL       = ['Helvetica', 9];

# ---------------------------------------------------------------------------
# State Variables
# ---------------------------------------------------------------------------
my $active_tab = 'movies';  # 'movies' or 'shows'
my $search_var = '';        # Live search query
my $stats_var  = 'Loading...';
my $progress_var = 'Ready';
my $overwrite_files = 0;

my $sort_col     = 'title';
my $sort_order   = 'asc';

# Selection details variables
my $detail_title_var = '';
my $detail_year_var  = '';
my $detail_rating_var = '';
my $detail_status_var = '';
my $detail_added_var  = '';
my $detail_extra_label_var = 'Extra:';
my $detail_extra_var = '';
my $detail_source_var = '';
my $detail_dest_var = '';
my $detail_size_var = '';

# Data arrays
my @all_movies;
my @all_shows;
my @displayed_items; # Currently matching search query

# Scanned directory indices
my %local_movies;       # cleaned_title -> { path => ..., folder_name => ... }
my %local_shows;        # cleaned_title -> { path => ..., folder_name => ... }
my %bigstorage_movies;  # cleaned_title_folder -> folder_name (exist on target)
my %bigstorage_shows;   # cleaned_title_folder -> folder_name (exist on target)

# Load mounting configuration
my $shares_file = '/home/timmccarthey/Public/shares.json';
my %shares;
if (-f $shares_file) {
    if (open(my $fh, '<', $shares_file)) {
        local $/;
        my $json_text = <$fh>;
        close($fh);
        eval {
            my $shares_ref = decode_json($json_text);
            %shares = %{$shares_ref};
        };
    }
}

my $mount_opts_template = join(',',
    'credentials=CREDS',
    'iocharset=utf8',
    'file_mode=0777',
    'dir_mode=0777',
    'soft',
    'noperm',
);

# ---------------------------------------------------------------------------
# UI Construction
# ---------------------------------------------------------------------------
my $mw = MainWindow->new;
$mw->title("Plex Storage Copier");
$mw->geometry("960x820");
$mw->configure(-bg => $C_BG);

# Setup Tag Styles for the Log Console
# (Note: We configure the text tags after the main text widget is created)

# Main Title Frame
my $title_frame = $mw->Frame(
    -bg          => $C_PANEL,
    -relief      => 'flat',
    -borderwidth => 0,
)->pack(-side => 'top', -fill => 'x');

$title_frame->Label(
    -text   => " Plex Storage Copier",
    -font   => $F_TITLE,
    -bg     => $C_PANEL,
    -fg     => '#2D7DD2',
    -anchor => 'w',
)->pack(-side => 'left', -padx => 15, -pady => 12);

my $stats_label = $title_frame->Label(
    -textvariable => \$stats_var,
    -font         => $F_BOLD,
    -bg           => $C_PANEL,
    -fg           => $C_SUBTEXT,
    -anchor       => 'e',
)->pack(-side => 'right', -padx => 15, -pady => 12);

# Subtle accent separator line under title bar
$mw->Frame(-bg => $C_BORDER, -height => 1)->pack(-side => 'top', -fill => 'x');

# Control row (Tabs on left, search on right)
my $control_frame = $mw->Frame(-bg => $C_BG)
    ->pack(-side => 'top', -fill => 'x', -padx => 15, -pady => 10);

my $tab_frame = $control_frame->Frame(-bg => $C_BG)->pack(-side => 'left');

my $movies_tab_btn = make_button($tab_frame,
    -text             => 'Movies',
    -bg               => $C_HDR_LOCAL,
    -activebackground => $C_HDR_LOCAL,
    -command          => sub { switch_tab('movies') },
)->pack(-side => 'left', -padx => 2);

my $shows_tab_btn = make_button($tab_frame,
    -text             => 'TV Shows',
    -bg               => $C_BTN_BG,
    -activebackground => $C_BTN_ACT,
    -command          => sub { switch_tab('shows') },
)->pack(-side => 'left', -padx => 2);

# Search bar
my $search_frame = $control_frame->Frame(-bg => $C_BG)->pack(-side => 'right');
$search_frame->Label(
    -text => 'Search: ',
    -font => $F_BOLD,
    -bg   => $C_BG,
    -fg   => $C_TEXT,
)->pack(-side => 'left');

my $search_entry = $search_frame->Entry(
    -textvariable     => \$search_var,
    -bg               => $C_PANEL,
    -fg               => $C_TEXT,
    -insertbackground => $C_TEXT, # Caret color
    -font             => $F_NORMAL,
    -width            => 25,
    -relief           => 'flat',
    -borderwidth      => 1,
)->pack(-side => 'left', -padx => 5, -pady => 5);
$search_entry->bind('<KeyRelease>', \&update_list);

# Header indicator for columns (click to sort)
my $header_frame = $mw->Frame(
    -bg => $C_BG,
)->pack(-side => 'top', -fill => 'x', -padx => 18, -pady => '5 0');

my $title_hdr_lbl = $header_frame->Label(
    -text   => " Title ▲",
    -font   => $F_MONO,
    -bg     => $C_BG,
    -fg     => $C_SUBTEXT,
    -width  => 43,
    -anchor => 'w',
    -cursor => 'hand2',
)->pack(-side => 'left');

my $year_hdr_lbl = $header_frame->Label(
    -text   => "Year",
    -font   => $F_MONO,
    -bg     => $C_BG,
    -fg     => $C_SUBTEXT,
    -width  => 8,
    -anchor => 'w',
    -cursor => 'hand2',
)->pack(-side => 'left');

my $added_hdr_lbl = $header_frame->Label(
    -text   => "Added",
    -font   => $F_MONO,
    -bg     => $C_BG,
    -fg     => $C_SUBTEXT,
    -width  => 14,
    -anchor => 'w',
    -cursor => 'hand2',
)->pack(-side => 'left');

my $status_hdr_lbl = $header_frame->Label(
    -text   => "Status",
    -font   => $F_MONO,
    -bg     => $C_BG,
    -fg     => $C_SUBTEXT,
    -anchor => 'w',
    -cursor => 'hand2',
)->pack(-side => 'left');

$title_hdr_lbl->bind('<Button-1>', sub { toggle_sort('title') });
$year_hdr_lbl->bind('<Button-1>', sub { toggle_sort('year') });
$added_hdr_lbl->bind('<Button-1>', sub { toggle_sort('added') });
$status_hdr_lbl->bind('<Button-1>', sub { toggle_sort('status') });

# Listbox and scrollbar container
my $list_frame = $mw->Frame(-bg => $C_PANEL)
    ->pack(-side => 'top', -fill => 'both', -expand => 1, -padx => 15, -pady => 5);

my $scrollbar = $list_frame->Scrollbar(
    -bg               => $C_PANEL,
    -activebackground => $C_BTN_ACT,
)->pack(-side => 'right', -fill => 'y');

my $listbox = $list_frame->Listbox(
    -selectmode         => 'extended',
    -bg                 => $C_PANEL,
    -fg                 => $C_TEXT,
    -selectbackground   => $C_SEL_BG,
    -selectforeground   => $C_SEL_FG,
    -font               => $F_MONO,
    -yscrollcommand     => ['set', $scrollbar],
    -relief             => 'flat',
    -borderwidth        => 0,
    -highlightthickness => 0,
)->pack(-side => 'left', -fill => 'both', -expand => 1);
$scrollbar->configure(-command => ['yview', $listbox]);

$listbox->bind('<<ListboxSelect>>', \&on_listbox_select);

# Selection controls row
my $sel_ctrl_frame = $mw->Frame(-bg => $C_BG)
    ->pack(-side => 'top', -fill => 'x', -padx => 15, -pady => 5);

make_button($sel_ctrl_frame,
    -text    => 'Select All Available',
    -command => \&select_all_available,
)->pack(-side => 'left', -padx => 2);

make_button($sel_ctrl_frame,
    -text    => 'Deselect All',
    -command => \&deselect_all,
)->pack(-side => 'left', -padx => 2);

make_button($sel_ctrl_frame,
    -text    => 'Refresh',
    -command => \&refresh_all,
)->pack(-side => 'left', -padx => 2);

my $overwrite_cb = $sel_ctrl_frame->Checkbutton(
    -text             => 'Overwrite Existing Files',
    -variable         => \$overwrite_files,
    -bg               => $C_BG,
    -fg               => $C_TEXT,
    -activebackground => $C_BG,
    -activeforeground => $C_TEXT,
    -selectcolor      => $C_PANEL,
    -font             => $F_BOLD,
)->pack(-side => 'right', -padx => 5);

# Info label explaining how to select multiple
$sel_ctrl_frame->Label(
    -text => "(Ctrl+Click or Shift+Click to multi-select)",
    -font => $F_SMALL,
    -bg   => $C_BG,
    -fg   => $C_SUBTEXT,
)->pack(-side => 'right', -padx => 10);

# Detailed Info Panel
my $details_frame = $mw->Frame(
    -bg          => $C_PANEL,
    -relief      => 'flat',
    -borderwidth => 1,
)->pack(-side => 'top', -fill => 'x', -padx => 15, -pady => 5);

my $det_row1 = $details_frame->Frame(-bg => $C_PANEL)->pack(-side => 'top', -fill => 'x', -padx => 10, -pady => 5);
$det_row1->Label(-text => "Title: ", -font => $F_BOLD, -bg => $C_PANEL, -fg => $C_SUBTEXT)->pack(-side => 'left');
$det_row1->Label(-textvariable => \$detail_title_var, -font => $F_BOLD, -bg => $C_PANEL, -fg => $C_TEXT)->pack(-side => 'left', -padx => '0 20');

$det_row1->Label(-text => "Year: ", -font => $F_BOLD, -bg => $C_PANEL, -fg => $C_SUBTEXT)->pack(-side => 'left');
$det_row1->Label(-textvariable => \$detail_year_var, -font => $F_NORMAL, -bg => $C_PANEL, -fg => $C_TEXT)->pack(-side => 'left', -padx => '0 20');

$det_row1->Label(-text => "Rating: ", -font => $F_BOLD, -bg => $C_PANEL, -fg => $C_SUBTEXT)->pack(-side => 'left');
$det_row1->Label(-textvariable => \$detail_rating_var, -font => $F_NORMAL, -bg => $C_PANEL, -fg => $C_TEXT)->pack(-side => 'left', -padx => '0 20');

my $extra_lbl = $det_row1->Label(-textvariable => \$detail_extra_label_var, -font => $F_BOLD, -bg => $C_PANEL, -fg => $C_SUBTEXT)->pack(-side => 'left');
$det_row1->Label(-textvariable => \$detail_extra_var, -font => $F_NORMAL, -bg => $C_PANEL, -fg => $C_TEXT)->pack(-side => 'left');

my $det_row2 = $details_frame->Frame(-bg => $C_PANEL)->pack(-side => 'top', -fill => 'x', -padx => 10, -pady => 5);
$det_row2->Label(-text => "Status: ", -font => $F_BOLD, -bg => $C_PANEL, -fg => $C_SUBTEXT)->pack(-side => 'left');
my $status_val_lbl = $det_row2->Label(-textvariable => \$detail_status_var, -font => $F_BOLD, -bg => $C_PANEL, -fg => '#F59E0B')->pack(-side => 'left', -padx => '0 20');

$det_row2->Label(-text => "Folder Size: ", -font => $F_BOLD, -bg => $C_PANEL, -fg => $C_SUBTEXT)->pack(-side => 'left');
$det_row2->Label(-textvariable => \$detail_size_var, -font => $F_NORMAL, -bg => $C_PANEL, -fg => $C_TEXT)->pack(-side => 'left', -padx => '0 10');
my $calc_size_button = make_button($det_row2,
    -text    => 'Calculate Size',
    -font    => $F_SMALL,
    -pady    => 2,
    -state   => 'disabled',
    -command => \&calculate_selected_size,
)->pack(-side => 'left');

my $det_row3 = $details_frame->Frame(-bg => $C_PANEL)->pack(-side => 'top', -fill => 'x', -padx => 10, -pady => 5);
$det_row3->Label(-text => "Local Path:  ", -font => $F_BOLD, -bg => $C_PANEL, -fg => $C_SUBTEXT)->pack(-side => 'left');
my $src_entry = $det_row3->Entry(
    -textvariable => \$detail_source_var,
    -font         => $F_SMALL,
    -bg           => $C_PANEL,
    -fg           => $C_TEXT,
    -relief       => 'flat',
    -state        => 'readonly',
    -width        => 105,
)->pack(-side => 'left');

my $det_row4 = $details_frame->Frame(-bg => $C_PANEL)->pack(-side => 'top', -fill => 'x', -padx => 10, -pady => 5);
$det_row4->Label(-text => "Target Path: ", -font => $F_BOLD, -bg => $C_PANEL, -fg => $C_SUBTEXT)->pack(-side => 'left');
my $dst_entry = $det_row4->Entry(
    -textvariable => \$detail_dest_var,
    -font         => $F_SMALL,
    -bg           => $C_PANEL,
    -fg           => $C_TEXT,
    -relief       => 'flat',
    -state        => 'readonly',
    -width        => 105,
)->pack(-side => 'left');

# Action button
my $action_frame = $mw->Frame(-bg => $C_BG)
    ->pack(-side => 'top', -fill => 'x', -padx => 15, -pady => 8);

my $copy_button = make_button($action_frame,
    -text             => 'COPY SELECTED TO BIGSTORAGE',
    -bg               => '#10B981', # Emerald Green
    -fg               => '#FFFFFF',
    -activebackground => '#059669',
    -font             => ['Helvetica', 12, 'bold'],
    -command          => \&run_copy_process,
)->pack(-fill => 'x');

# Progress and Log Console
my $log_frame = $mw->Frame(-bg => $C_BG)
    ->pack(-side => 'top', -fill => 'both', -expand => 1, -padx => 15, -pady => 5);

$log_frame->Label(
    -textvariable => \$progress_var,
    -font         => $F_BOLD,
    -bg           => $C_BG,
    -fg           => '#F59E0B',
    -anchor       => 'w',
)->pack(-side => 'top', -fill => 'x', -pady => 2);

my $log_scroll = $log_frame->Scrollbar(
    -bg               => $C_PANEL,
    -activebackground => $C_BTN_ACT,
)->pack(-side => 'right', -fill => 'y');

my $log_text = $log_frame->Text(
    -bg             => '#0D0D16',
    -fg             => '#ECECF1',
    -font           => $F_MONO,
    -yscrollcommand => ['set', $log_scroll],
    -relief         => 'flat',
    -borderwidth    => 0,
    -height         => 7,
    -state          => 'disabled',
)->pack(-side => 'left', -fill => 'both', -expand => 1);
$log_scroll->configure(-command => ['yview', $log_text]);

# Configure Text Tags for colored output in Console Log
$log_text->tagConfigure('normal',  -foreground => '#ECECF1');
$log_text->tagConfigure('success', -foreground => '#4ADE80');
$log_text->tagConfigure('warning', -foreground => '#F59E0B');
$log_text->tagConfigure('error',   -foreground => '#F87171');
$log_text->tagConfigure('info',    -foreground => '#60A5FA');

# ---------------------------------------------------------------------------
# Main Logic Initializations
# ---------------------------------------------------------------------------
log_message("Plex Storage Copier Initialized.", 'info');

$mw->after(100, sub {
    mount_share('tim-movies');
    mount_share('tim-shows');

    log_message("Cleaning empty folders in TimMovies...", 'info');
    clean_empty_directories('/home/timmccarthey/Public/TimMovies');

    log_message("Cleaning empty folders in TimShows...", 'info');
    clean_empty_directories('/home/timmccarthey/Public/TimShows');

    log_message("Updating Plex CSV exports (running plex_export.py)...", 'info');
    my $export_output = `python3 /home/timmccarthey/Public/plex_export.py 2>&1`;
    if ($? == 0) {
        log_message("Plex export completed successfully.", 'success');
    } else {
        log_message("Error running plex_export.py:\n$export_output", 'error');
    }

    refresh_all();
});

$mw->protocol('WM_DELETE_WINDOW', sub {
    unmount_share('tim-movies');
    unmount_share('tim-shows');
    $mw->destroy;
});

MainLoop;

# ---------------------------------------------------------------------------
# Helper Subroutines
# ---------------------------------------------------------------------------
sub make_button {
    my ($parent, %opts) = @_;
    my $bg  = delete $opts{-bg}  // $C_BTN_BG;
    my $fg  = delete $opts{-fg}  // $C_BTN_FG;
    my $abg = delete $opts{-activebackground} // $C_BTN_ACT;
    return $parent->Button(
        -bg               => $bg,
        -fg               => $fg,
        -activebackground => $abg,
        -activeforeground => $C_HDR_FG,
        -relief           => 'flat',
        -borderwidth      => 0,
        -padx             => 12,
        -pady             => 6,
        -cursor           => 'hand2',
        -font             => $F_BOLD,
        %opts,
    );
}

sub log_message {
    my ($msg, $color_tag) = @_;
    $color_tag //= 'normal';
    
    if ($color_tag =~ /^#/) {
        my $tag_name = "color_" . $color_tag;
        $tag_name =~ s/#//g;
        $log_text->tagConfigure($tag_name, -foreground => $color_tag);
        $color_tag = $tag_name;
    }
    
    $log_text->configure(-state => 'normal');
    $log_text->insert('end', $msg . "\n", $color_tag);
    $log_text->see('end');
    $log_text->configure(-state => 'disabled');
    $mw->update;
}

sub clean_name {
    my $name = shift;
    return "" unless defined $name;
    $name = lc($name);
    $name =~ s/\((19|20)\d{2}\)//g; # Remove (YYYY)
    $name =~ s/\b(19|20)\d{2}\b//g; # Remove YYYY
    $name =~ s/\{tmdb-\d+\}//g;     # Remove {tmdb-ID}
    $name =~ s/[^a-z0-9]//g;        # Remove dots, spaces, special chars
    return $name;
}

sub parse_csv_line {
    my $line = shift;
    my @fields = ();
    while ($line =~ /\s*(?:"([^"]*(?:""[^"]*)*)"|([^,]*))\s*(?:,|$)/g) {
        my $val = (defined $1) ? $1 : $2;
        if (defined $1) { $val =~ s/""/"/g; }
        push @fields, $val;
        last if pos($line) >= length($line);
    }
    return @fields;
}

sub load_movies_csv {
    my $file = '/home/timmccarthey/Public/plex_movies.csv';
    return undef unless -f $file;
    open(my $fh, '<', $file) or return undef;
    my $header = <$fh>;
    my @items;
    while (my $line = <$fh>) {
        chomp $line;
        next if $line =~ /^\s*$/;
        my @fields = parse_csv_line($line);
        next unless @fields;
        my ($title, $year, $rating, $studio, $added, $path, $filename) = @fields;
        push @items, {
            type     => 'movie',
            title    => $title // '',
            year     => $year // '',
            rating   => $rating // '',
            studio   => $studio // '',
            added    => $added // '',
            raw_path => $path // '',
            filename => $filename // '',
        };
    }
    close($fh);
    return \@items;
}

sub load_shows_csv {
    my $file = '/home/timmccarthey/Public/plex_tv_shows.csv';
    return undef unless -f $file;
    open(my $fh, '<', $file) or return undef;
    my $header = <$fh>;
    my @items;
    while (my $line = <$fh>) {
        chomp $line;
        next if $line =~ /^\s*$/;
        my @fields = parse_csv_line($line);
        next unless @fields;
        my ($title, $seasons, $year, $rating, $season_count, $episodes, $added) = @fields;
        push @items, {
            type         => 'show',
            title        => $title // '',
            seasons      => $seasons // '',
            year         => $year // '',
            rating       => $rating // '',
            season_count => $season_count // '',
            episodes     => $episodes // '',
            added        => $added // '',
        };
    }
    close($fh);
    return \@items;
}

sub scan_local_media {
    %local_movies = ();
    %local_shows  = ();

    # Scan Movies categories
    my $movies_root = '/home/timmccarthey/Public/TimMovies';
    if (-d $movies_root) {
        if (opendir(my $dh, $movies_root)) {
            while (my $cat = readdir($dh)) {
                next if $cat =~ /^\./;
                my $cat_path = File::Spec->catdir($movies_root, $cat);
                if (-d $cat_path) {
                    if (opendir(my $subdh, $cat_path)) {
                        while (my $folder = readdir($subdh)) {
                            next if $folder =~ /^\./;
                            my $folder_path = File::Spec->catdir($cat_path, $folder);
                            if (-d $folder_path) {
                                my $cleaned = clean_name($folder);
                                $local_movies{$cleaned} = {
                                    path        => $folder_path,
                                    folder_name => $folder,
                                };
                            }
                        }
                        closedir($subdh);
                    }
                }
            }
            closedir($dh);
        }
    }

    # Scan Shows
    my $shows_root = '/home/timmccarthey/Public/TimShows';
    if (-d $shows_root) {
        if (opendir(my $dh, $shows_root)) {
            while (my $folder = readdir($dh)) {
                next if $folder =~ /^\./;
                my $folder_path = File::Spec->catdir($shows_root, $folder);
                if (-d $folder_path) {
                    my $cleaned = clean_name($folder);
                    $local_shows{$cleaned} = {
                        path        => $folder_path,
                        folder_name => $folder,
                    };
                }
            }
            closedir($dh);
        }
    }
}

sub scan_bigstorage {
    %bigstorage_movies = ();
    %bigstorage_shows  = ();

    my $dest_movies = '/home/timmccarthey/Public/BIGSTORAGE/Movies';
    if (-d $dest_movies) {
        if (opendir(my $dh, $dest_movies)) {
            while (my $folder = readdir($dh)) {
                next if $folder =~ /^\./;
                if (-d File::Spec->catdir($dest_movies, $folder)) {
                    $bigstorage_movies{clean_name($folder)} = $folder;
                }
            }
            closedir($dh);
        }
    }

    my $dest_shows = '/home/timmccarthey/Public/BIGSTORAGE/Shows';
    if (-d $dest_shows) {
        if (opendir(my $dh, $dest_shows)) {
            while (my $folder = readdir($dh)) {
                next if $folder =~ /^\./;
                if (-d File::Spec->catdir($dest_shows, $folder)) {
                    $bigstorage_shows{clean_name($folder)} = $folder;
                }
            }
            closedir($dh);
        }
    }
}

sub update_items_status {
    # Resolve movies status
    for my $item (@all_movies) {
        my $src_path = '';
        my $folder_name = '';
        
        # 1. Direct path check from CSV path column
        if ($item->{raw_path}) {
            my $local_p = $item->{raw_path};
            $local_p =~ s|^\Q/volume1/docker/Plex/Movies/DVD/\E|/home/timmccarthey/Public/TimMovies/|;
            my ($filename, $dirs) = fileparse($local_p);
            $dirs =~ s|/$||;
            if (-d $dirs) {
                $src_path = $dirs;
                $folder_name = basename($dirs);
            }
        }
        
        # 2. Fallback to clean title lookup in scan map
        if (!$src_path) {
            my $cleaned = clean_name($item->{title});
            if (exists $local_movies{$cleaned}) {
                $src_path = $local_movies{$cleaned}->{path};
                $folder_name = $local_movies{$cleaned}->{folder_name};
            }
        }
        
        if ($src_path) {
            $item->{source_path} = $src_path;
            $item->{folder_name} = $folder_name;
            $item->{dest_path}   = File::Spec->catdir('/home/timmccarthey/Public/BIGSTORAGE/Movies', $folder_name);
            
            my $cleaned_folder = clean_name($folder_name);
            if (exists $bigstorage_movies{$cleaned_folder}) {
                $item->{status} = 'Already on BIGSTORAGE';
            } else {
                $item->{status} = 'Available';
            }
        } else {
            $item->{source_path} = '';
            $item->{dest_path}   = '';
            $item->{status}      = 'Not Found Locally';
        }
    }
    
    # Resolve TV shows status
    for my $item (@all_shows) {
        my $cleaned = clean_name($item->{title});
        if (exists $local_shows{$cleaned}) {
            my $src_path = $local_shows{$cleaned}->{path};
            my $folder_name = $local_shows{$cleaned}->{folder_name};
            
            $item->{source_path} = $src_path;
            $item->{folder_name} = $folder_name;
            $item->{dest_path}   = File::Spec->catdir('/home/timmccarthey/Public/BIGSTORAGE/Shows', $folder_name);
            
            my $cleaned_folder = clean_name($folder_name);
            if (exists $bigstorage_shows{$cleaned_folder}) {
                $item->{status} = 'Already on BIGSTORAGE';
            } else {
                $item->{status} = 'Available';
            }
        } else {
            $item->{source_path} = '';
            $item->{dest_path}   = '';
            $item->{status}      = 'Not Found Locally';
        }
    }
    
    update_stats_label();
}

sub update_stats_label {
    my $avail_movies = grep { $_->{status} eq 'Available' } @all_movies;
    my $copied_movies = grep { $_->{status} eq 'Already on BIGSTORAGE' } @all_movies;
    
    my $avail_shows = grep { $_->{status} eq 'Available' } @all_shows;
    my $copied_shows = grep { $_->{status} eq 'Already on BIGSTORAGE' } @all_shows;
    
    $stats_var = sprintf("Movies: %d/%d avail (copied: %d) | Shows: %d/%d avail (copied: %d)",
        $avail_movies, scalar(@all_movies), $copied_movies,
        $avail_shows, scalar(@all_shows), $copied_shows
    );
}

sub truncate_str {
    my ($str, $len) = @_;
    if (length($str) > $len) {
        return substr($str, 0, $len - 3) . "...";
    }
    return $str;
}

sub update_list {
    my $query = lc($search_var);
    $listbox->delete(0, 'end');
    @displayed_items = ();
    
    my $source_list = ($active_tab eq 'movies') ? \@all_movies : \@all_shows;
    
    my @sorted_list = sort {
        my $val_a = $a->{$sort_col} // '';
        my $val_b = $b->{$sort_col} // '';
        
        $val_a = lc($val_a);
        $val_b = lc($val_b);
        
        my $cmp;
        if ($sort_col eq 'year') {
            $val_a =~ s/\D//g;
            $val_b =~ s/\D//g;
            $val_a ||= 0;
            $val_b ||= 0;
            $cmp = $val_a <=> $val_b;
        } else {
            $cmp = $val_a cmp $val_b;
        }
        
        if ($cmp == 0) {
            $cmp = lc($a->{title} // '') cmp lc($b->{title} // '');
        }
        
        return ($sort_order eq 'asc') ? $cmp : -$cmp;
    } @$source_list;
    
    my $idx = 0;
    for my $item (@sorted_list) {
        my $title = $item->{title};
        if ($query ne '') {
            next unless index(lc($title), $query) != -1;
        }
        
        push @displayed_items, $item;
        
        my $status = $item->{status};
        my $year   = $item->{year} || '????';
        
        my $title_col = truncate_str($title, 40);
        my $added_date = $item->{added} || '????-??-??';
        my $display_str = sprintf(" %-42s  %-6s  %-12s  %s", $title_col, $year, $added_date, $status);
        
        $listbox->insert('end', $display_str);
        
        my $color = '#8E8E9F';
        if ($status eq 'Available') {
            $color = '#4ADE80';
        } elsif ($status eq 'Already on BIGSTORAGE') {
            $color = '#60A5FA';
        } elsif ($status eq 'Not Found Locally') {
            $color = '#F87171';
        }
        
        $listbox->itemconfigure($idx, -foreground => $color);
        $idx++;
    }
}

sub switch_tab {
    my $tab = shift;
    return if $active_tab eq $tab;
    $active_tab = $tab;
    
    if ($active_tab eq 'movies') {
        $movies_tab_btn->configure(-bg => $C_HDR_LOCAL, -activebackground => $C_HDR_LOCAL);
        $shows_tab_btn->configure(-bg => $C_BTN_BG, -activebackground => $C_BTN_ACT);
    } else {
        $movies_tab_btn->configure(-bg => $C_BTN_BG, -activebackground => $C_BTN_ACT);
        $shows_tab_btn->configure(-bg => $C_HDR_REMOTE, -activebackground => $C_HDR_REMOTE);
    }
    
    update_list();
    clear_details();
}

sub toggle_sort {
    my ($col) = @_;
    if ($sort_col eq $col) {
        $sort_order = ($sort_order eq 'asc') ? 'desc' : 'asc';
    } else {
        $sort_col   = $col;
        $sort_order = 'asc';
    }
    
    update_header_labels();
    update_list();
}

sub update_header_labels {
    $title_hdr_lbl->configure(-text  => " Title" . ($sort_col eq 'title' ? ($sort_order eq 'asc' ? " ▲" : " ▼") : ""));
    $year_hdr_lbl->configure(-text   => "Year" . ($sort_col eq 'year' ? ($sort_order eq 'asc' ? " ▲" : " ▼") : ""));
    $added_hdr_lbl->configure(-text  => "Added" . ($sort_col eq 'added' ? ($sort_order eq 'asc' ? " ▲" : " ▼") : ""));
    $status_hdr_lbl->configure(-text => "Status" . ($sort_col eq 'status' ? ($sort_order eq 'asc' ? " ▲" : " ▼") : ""));
}

sub clear_details {
    $detail_title_var = '';
    $detail_year_var  = '';
    $detail_rating_var = '';
    $detail_status_var = '';
    $detail_extra_label_var = 'Extra:';
    $detail_extra_var = '';
    $detail_source_var = '';
    $detail_dest_var = '';
    $detail_size_var = '';
    $calc_size_button->configure(-state => 'disabled');
}

sub on_listbox_select {
    my @selections = $listbox->curselection;
    return unless @selections;
    
    my $first_sel = $selections[0];
    my $item = $displayed_items[$first_sel];
    return unless $item;
    
    $detail_title_var  = $item->{title};
    $detail_year_var   = $item->{year};
    $detail_rating_var = $item->{rating} || 'N/A';
    $detail_status_var = $item->{status};
    
    # Configure status color depending on status
    if ($item->{status} eq 'Available') {
        $status_val_lbl->configure(-fg => '#4ADE80');
    } elsif ($item->{status} eq 'Already on BIGSTORAGE') {
        $status_val_lbl->configure(-fg => '#60A5FA');
    } else {
        $status_val_lbl->configure(-fg => '#F87171');
    }
    
    if ($item->{type} eq 'movie') {
        $detail_extra_label_var = "Studio: ";
        $detail_extra_var = $item->{studio} || 'N/A';
    } else {
        $detail_extra_label_var = "Episodes: ";
        $detail_extra_var = ($item->{season_count} ? "$item->{season_count} Seasons, " : "") . ($item->{episodes} ? "$item->{episodes} Episodes" : "N/A");
    }
    
    if ($item->{source_path}) {
        $detail_source_var = $item->{source_path};
        $detail_dest_var   = $item->{dest_path};
        $detail_size_var   = "Click 'Calculate Size' to scan";
        $calc_size_button->configure(-state => 'normal');
    } else {
        $detail_source_var = "N/A (Not Found)";
        $detail_dest_var   = "N/A";
        $detail_size_var   = "N/A";
        $calc_size_button->configure(-state => 'disabled');
    }
}

sub get_folder_size {
    my $dir = shift;
    return 0 unless -d $dir;
    my $size = 0;
    find(sub { $size += -f $_ ? -s $_ : 0 }, $dir);
    return $size;
}

sub format_size {
    my $bytes = shift;
    if ($bytes >= 1024 * 1024 * 1024) {
        return sprintf("%.2f GB", $bytes / (1024 * 1024 * 1024));
    } elsif ($bytes >= 1024 * 1024) {
        return sprintf("%.2f MB", $bytes / (1024 * 1024));
    } elsif ($bytes >= 1024) {
        return sprintf("%.2f KB", $bytes / 1024);
    } else {
        return "$bytes Bytes";
    }
}

sub calculate_selected_size {
    my @selections = $listbox->curselection;
    return unless @selections;
    
    my $item = $displayed_items[$selections[0]];
    return unless $item && $item->{source_path};
    
    $detail_size_var = "Calculating...";
    $mw->update;
    
    my $bytes = get_folder_size($item->{source_path});
    $detail_size_var = format_size($bytes);
}

sub select_all_available {
    $listbox->selectionClear(0, 'end');
    my $idx = 0;
    for my $item (@displayed_items) {
        if ($item->{status} eq 'Available') {
            $listbox->selectionSet($idx);
        }
        $idx++;
    }
    on_listbox_select();
}

sub deselect_all {
    $listbox->selectionClear(0, 'end');
    clear_details();
}

sub refresh_all {
    $progress_var = "Scanning directories...";
    $mw->update;
    
    scan_local_media();
    scan_bigstorage();
    
    my $movies_ref = load_movies_csv();
    if ($movies_ref) {
        @all_movies = @$movies_ref;
    } else {
        log_message("Error: Could not load Movies CSV from /home/timmccarthey/Public/plex_movies.csv", 'error');
    }
    
    my $shows_ref = load_shows_csv();
    if ($shows_ref) {
        @all_shows = @$shows_ref;
    } else {
        log_message("Error: Could not load Shows CSV from /home/timmccarthey/Public/plex_tv_shows.csv", 'error');
    }
    
    update_items_status();
    update_list();
    clear_details();
    
    $progress_var = "Ready";
    log_message("Mounts scanned and CSVs loaded successfully.", 'success');
}

sub get_free_space_gb {
    my $dir = shift;
    return undef unless -d $dir;
    my $df_out = `df -BG "$dir" | awk 'NR==2 {print \$4}'`;
    if ($df_out) {
        $df_out =~ s/G//g;
        return int($df_out);
    }
    return undef;
}

sub chunked_file_copy {
    my ($src, $dest) = @_;
    
    if (!$overwrite_files && -e $dest) {
        return;
    }
    
    my $dir = dirname($dest);
    make_path($dir) unless -d $dir;
    
    open(my $in,  '<:raw', $src)  or die "Cannot open $src: $!";
    open(my $out, '>:raw', $dest) or die "Cannot open $dest: $!";
    
    my $buf = '';
    while (my $bytes = read($in, $buf, 1024 * 1024)) {
        print $out $buf or die "Write failed: $!";
        $mw->update;
    }
    
    close($in);
    close($out);
}

sub copy_dir_with_progress {
    my ($src_dir, $dst_dir) = @_;
    
    make_path($dst_dir) unless -d $dst_dir;
    
    opendir(my $dh, $src_dir) or die "Cannot read $src_dir: $!";
    my @entries = grep { $_ ne '.' && $_ ne '..' } readdir($dh);
    closedir($dh);
    
    for my $entry (@entries) {
        my $src  = File::Spec->catfile($src_dir, $entry);
        my $dest = File::Spec->catfile($dst_dir, $entry);
        
        if (-d $src) {
            copy_dir_with_progress($src, $dest);
        } else {
            log_message("    Copying: $entry");
            $progress_var = "Copying: $entry";
            $mw->update;
            chunked_file_copy($src, $dest);
        }
    }
}

sub run_copy_process {
    my @selections = $listbox->curselection;
    if (!@selections) {
        $mw->messageBox(
            -title   => 'No Selection',
            -message => 'Please select at least one movie or show to copy.',
            -type    => 'OK',
            -icon    => 'info',
        );
        return;
    }
    
    my @items_to_copy;
    for my $idx (@selections) {
        my $item = $displayed_items[$idx];
        if ($item && $item->{source_path}) {
            push @items_to_copy, $item;
        } else {
            my $title = $item ? $item->{title} : "Unknown";
            log_message("Skipping '$title' - not found locally.", 'error');
        }
    }
    
    if (!@items_to_copy) {
        $mw->messageBox(
            -title   => 'No Valid Selection',
            -message => 'None of the selected items are available locally for copying.',
            -type    => 'OK',
            -icon    => 'warning',
        );
        return;
    }
    
    my $dest_dir = '/home/timmccarthey/Public/BIGSTORAGE';
    if (!-d $dest_dir) {
        $mw->messageBox(
            -title   => 'Destination Error',
            -message => "Destination folder $dest_dir does not exist or is not mounted.\nPlease mount BIGSTORAGE and try again.",
            -type    => 'OK',
            -icon    => 'error',
        );
        return;
    }
    
    my $free_gb = get_free_space_gb($dest_dir);
    if (defined $free_gb) {
        log_message("Available space on BIGSTORAGE: ${free_gb}GB", 'info');
        if ($free_gb < 5) {
            $mw->messageBox(
                -title   => 'Low Space Warning',
                -message => "Less than 5GB of free space remaining on BIGSTORAGE (${free_gb}GB available).\nAborting operation.",
                -type    => 'OK',
                -icon    => 'warning',
            );
            return;
        }
    }
    
    my $confirm = $mw->messageBox(
        -title   => 'Confirm Copy',
        -message => sprintf("Are you sure you want to copy %d item(s) to BIGSTORAGE?\n\nOverwrite Existing: %s",
            scalar(@items_to_copy),
            $overwrite_files ? "YES" : "NO"
        ),
        -type    => 'YesNo',
        -icon    => 'question',
    );
    return unless lc($confirm) eq 'yes';
    
    $copy_button->configure(-state => 'disabled', -text => 'COPYING...');
    $mw->update;
    
    my $success_count = 0;
    my $skipped_count = 0;
    my $failed_count  = 0;
    
    my $total_items = scalar(@items_to_copy);
    my $current_item = 0;
    
    log_message("Starting copy process for $total_items item(s)...", 'info');
    
    for my $item (@items_to_copy) {
        $current_item++;
        my $title = $item->{title};
        my $src = $item->{source_path};
        my $dst = $item->{dest_path};
        
        $progress_var = "Item $current_item of $total_items: Copying '$title'...";
        log_message("[$current_item/$total_items] Copying '$title'...", 'warning');
        log_message("  Source: $src");
        log_message("  Dest:   $dst");
        $mw->update;
        
        if (!-d $src) {
            log_message("  Error: Source folder does not exist: $src", 'error');
            $failed_count++;
            next;
        }
        
        if (!$overwrite_files && -d $dst) {
            log_message("  Skipped: Destination already exists (Overwrite is off).", 'normal');
            $skipped_count++;
            next;
        }
        
        eval {
            copy_dir_with_progress($src, $dst);
            log_message("  Successfully copied folder.", 'success');
            $success_count++;
        };
        if ($@) {
            log_message("  Error copying directory: $@", 'error');
            $failed_count++;
        }
    }
    
    # Rescan and refresh UI status
    scan_bigstorage();
    update_items_status();
    update_list();
    
    $progress_var = "Finished: $success_count successful, $skipped_count skipped, $failed_count failed.";
    log_message("Copy finished. Success: $success_count, Skipped: $skipped_count, Failed: $failed_count.", 'success');
    
    $copy_button->configure(-state => 'normal', -text => 'COPY SELECTED TO BIGSTORAGE');
    $mw->update;
}

sub is_mounted {
    my ($mount_point) = @_;
    return 0 unless -d $mount_point;
    return system('mountpoint', '-q', $mount_point) == 0;
}

sub mount_share {
    my ($name) = @_;
    my $cfg = $shares{$name} or return;
    if (is_mounted($cfg->{mount})) {
        log_message("Already mounted: $name", 'success');
        return;
    }

    log_message("Mounting $name...", 'info');
    
    my $opts = $mount_opts_template;
    $opts =~ s/CREDS/$cfg->{creds}/;

    system('sudo', 'mount', '-t', 'cifs', $cfg->{share}, $cfg->{mount}, '-o', $opts);

    if (is_mounted($cfg->{mount})) {
        log_message("Successfully mounted: $name", 'success');
    } else {
        log_message("Error: Mount failed for $name", 'error');
        $mw->messageBox(
            -title   => 'Mount Failed',
            -message => "Could not mount '$name'.\nCheck that the remote machine is online and credentials are correct.",
            -type    => 'OK',
            -icon    => 'error',
        );
    }
}

sub unmount_share {
    my ($name) = @_;
    my $cfg = $shares{$name} or return;
    return unless is_mounted($cfg->{mount});

    log_message("Unmounting $name...", 'info');

    my $max_retries = 3;
    for my $attempt (1 .. $max_retries) {
        system('sudo', 'umount', $cfg->{mount});
        last unless is_mounted($cfg->{mount});
        sleep 2 if $attempt < $max_retries;
    }

    if (is_mounted($cfg->{mount})) {
        system('sudo', 'umount', '-l', $cfg->{mount});
    }

    if (!is_mounted($cfg->{mount})) {
        log_message("Successfully unmounted: $name", 'success');
    } else {
        log_message("Error: Unmount failed for $name", 'error');
    }
}

sub clean_empty_directories {
    my ($root) = @_;
    return unless -d $root;
    
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
    
    if (@empty_dirs) {
        log_message("Found " . scalar(@empty_dirs) . " empty folder(s) under $root. Cleaning...", 'info');
        for my $dir (@empty_dirs) {
            log_message("  Removing empty folder: $dir", 'warning');
            if (rmdir($dir)) {
                log_message("    Removed successfully.", 'success');
            } else {
                log_message("    Failed to remove: $!", 'error');
            }
        }
    } else {
        log_message("No empty folders found under $root.", 'success');
    }
}
