#!/usr/bin/env perl

use strict;
use warnings;
use Tk;
use Tk::BrowseEntry;
use File::Basename;
use File::Find;
use File::Spec;
use File::Path qw(make_path);
use Encode qw(encode_utf8);
use JSON;
use File::Slurp;
use IPC::System::Simple qw(capture);

# Single-instance enforcement via PID lock file
my $LOCK_FILE = '/tmp/fileCopyGUI.lock';

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
            -message => "fileCopyGUI is already running (PID $pid).\nOnly one instance is allowed.",
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
# Color & font theme
# ---------------------------------------------------------------------------
# All colors are HTML hex strings (#RRGGBB).
# Edit these variables to retheme the entire UI — each variable is used
# consistently throughout the script, so changing it here changes it everywhere.
#
# BACKGROUNDS
my $C_BG         = '#1E1E2E';   # outermost window / frame background (darkest layer)
my $C_PANEL      = '#2A2A3E';   # pane background (sits on top of $C_BG)
my $C_CARD       = '#313145';   # listbox / inner card (dark variant — commented out)
my $C_BORDER     = '#44445A';   # subtle separator lines between UI sections

# PANE HEADER BARS  (the colored title bars above each file list)
my $C_HDR_LOCAL  = '#1A6BB5';   # local pane header — blue
my $C_HDR_REMOTE = '#A0303A';   # remote pane header — red/maroon (distinguishes remote from local)
my $C_HDR_FG     = '#FFFFFF';   # text color on both header bars

# NEUTRAL BUTTONS  (Sort, Refresh, Select All, etc.)
my $C_BTN_BG     = '#3A3A52';   # resting button background
my $C_BTN_FG     = '#E0E0F0';   # button label text
my $C_BTN_ACT    = '#4A4A6A';   # button background when pressed / hovered

# ACTION BUTTONS  (the big copy arrows)
my $C_BTN_GREEN     = '#1F6B3A';   # "copy to remote" button — green
my $C_BTN_GREEN_ACT = '#2A8A4A';   # "copy to remote" hover/active state
my $C_BTN_RED       = '#8B2020';   # "copy to local" button — red
my $C_BTN_RED_ACT   = '#A83030';   # "copy to local" hover/active state

# TEXT
my $C_TEXT       = '#E0E0F0';   # primary body text (filenames, labels)
my $C_SUBTEXT    = '#9090B0';   # secondary / dimmed text (file counts, hints)
my $C_SEL_BG     = '#1A6BB5';   # listbox selection highlight background (matches local header)
my $C_SEL_FG     = '#FFFFFF';   # listbox selection highlight text

# REMOTE SHARE SELECTOR  (the dropdown in the toolbar for picking dennis-movies, etc.)
#my $C_SHARE_FG   = '#E0E0F0';   # selected share text color — darken this value to make it easier to read
my $C_SHARE_FG   = '#11141c';   # selected share text color — darken this value to make it easier to read

# SORT DROPDOWNS  (the Sort: dropdowns in the local and remote panes)
my $C_SORT_FG    = '#11141c';   # sort selection text color — darken to taste

# STATUS BAR  (the strip along the bottom)
my $C_STATUS_BG  = '#141422';   # status bar background (slightly darker than $C_BG)
my $C_STATUS_FG  = '#8888AA';   # idle / informational status text
my $C_STATUS_OK  = '#5BA05B';   # success message text (green)

# FONTS  — [family, size] or [family, size, 'bold']
# Change 'Helvetica' to any font installed on your system (e.g. 'Arial', 'DejaVu Sans').
my $F_NORMAL  = ['Helvetica', 10];          # default label / listbox text
my $F_BOLD    = ['Helvetica', 10, 'bold'];  # emphasized labels
my $F_HEADER  = ['Helvetica', 12, 'bold'];  # pane header titles
my $F_SMALL   = ['Helvetica', 9];           # small hints / file counts
my $F_MONO    = ['Courier', 10];            # monospaced (used for paths)

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
my $json_text  = read_file('/home/timmccarthey/Public/shares.json');
my $shares_ref = decode_json($json_text);
my %shares     = %{$shares_ref};

my $mount_opts_template = join(',',
    'credentials=CREDS',
    'iocharset=utf8',
    'file_mode=0777',
    'dir_mode=0777',
    'soft',
    'noperm',
);

# ---------------------------------------------------------------------------
# Main window
# ---------------------------------------------------------------------------
my $mw = MainWindow->new;
$mw->title("File Copy");
$mw->geometry("1280x820");
$mw->configure(-bg => $C_BG);
$mw->optionAdd('*background',       $C_BG);
$mw->optionAdd('*foreground',       $C_TEXT);
$mw->optionAdd('*font',             $F_NORMAL);
$mw->optionAdd('*Entry.background', $C_CARD);
$mw->optionAdd('*Entry.foreground', $C_TEXT);
$mw->optionAdd('*Entry.insertBackground', $C_TEXT);
# BrowseEntry uses LabEntry internally; override its Entry foreground at the
# highest priority ('interactive') so it beats the *Entry.foreground rule above.
$mw->optionAdd('*LabEntry*Entry.foreground', $C_SORT_FG, 'interactive');

# BrowseEntry nests its Entry inside a LabEntry (BrowseEntry->LabEntry->Entry),
# so Subwidget('entry') doesn't reach it. This helper traverses to the real Entry.
sub browse_entry_fg {
    my ($be, $fg) = @_;
    my ($le) = grep { ref($_) eq 'Tk::LabEntry' } $be->children;
    return unless $le;
    my ($e) = $le->children;
    # BrowseEntry sets -state=>'readonly' by internally disabling the Entry,
    # so Tk renders text using -disabledforeground, not -foreground.
    $e->configure(-disabledforeground => $fg) if $e;
}

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------
my $selected_share    = '';
my $local_path        = '/home/timmccarthey/Public';
my $local_start_path  = '/home/timmccarthey/Public';
my $remote_path       = '';
my $remote_start_path = '';
my $local_sort        = 'Date (Newest)';
my $remote_sort       = 'Date (Newest)';

my ($local_listbox, $remote_listbox, $local_info, $remote_info, $status_label);

# ---------------------------------------------------------------------------
# Helper: styled button
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

# ---------------------------------------------------------------------------
# Toolbar
# ---------------------------------------------------------------------------
my $toolbar = $mw->Frame(
    -bg          => $C_PANEL,
    -relief      => 'flat',
    -borderwidth => 0,
)->pack(-side => 'top', -fill => 'x', -padx => 0, -pady => 0);

# thin accent line under toolbar
$mw->Frame(-bg => $C_HDR_LOCAL, -height => 2)
   ->pack(-side => 'top', -fill => 'x');

$toolbar->Label(
    -text   => 'Remote Share:',
    -bg     => $C_PANEL,
    -fg     => $C_SUBTEXT,
    -font   => $F_SMALL,
)->pack(-side => 'left', -padx => 16, -pady => 10);

my $share_entry = $toolbar->BrowseEntry(
    -variable => \$selected_share,
    -state    => 'readonly',
    -width    => 22,
    -choices  => [sort keys %shares],
    -browsecmd => \&load_remote_share,
    -bg       => $C_CARD,
    -fg       => $C_SHARE_FG,
    -font     => $F_NORMAL,
)->pack(-side => 'left', -padx => 4, -pady => 10);
# The global *Entry.foreground optionAdd overrides -fg on BrowseEntry, so we
# must set the color directly on the internal Entry subwidget after creation.
browse_entry_fg($share_entry, $C_SHARE_FG);

make_button($toolbar,
    -text    => 'Check Mounts',
    -command => \&check_mount_status,
)->pack(-side => 'left', -padx => 6, -pady => 10);

make_button($toolbar,
    -text    => 'Refresh Both',
    -command => sub { refresh_local_list(); refresh_remote_list(); },
)->pack(-side => 'left', -padx => 2, -pady => 10);

# App title on the right
$toolbar->Label(
    -text   => 'File Copy',
    -bg     => $C_PANEL,
    -fg     => $C_HDR_LOCAL,
    -font   => ['Helvetica', 13, 'bold'],
)->pack(-side => 'right', -padx => 16, -pady => 10);

# ---------------------------------------------------------------------------
# Dual-pane area
# ---------------------------------------------------------------------------
my $main_frame = $mw->Frame(-bg => $C_BG)
    ->pack(-side => 'top', -fill => 'both', -expand => 1, -padx => 12, -pady => 10);

# ---- LEFT PANE (Local) ----
my $left_pane = $main_frame->Frame(-bg => $C_PANEL, -relief => 'flat', -borderwidth => 0)
    ->pack(-side => 'left', -fill => 'both', -expand => 1, -padx => 6);

$left_pane->Frame(-bg => $C_HDR_LOCAL, -height => 4)->pack(-side => 'top', -fill => 'x');

$left_pane->Label(
    -text   => '  LOCAL FILES',
    -bg     => $C_HDR_LOCAL,
    -fg     => $C_HDR_FG,
    -font   => $F_HEADER,
    -anchor => 'w',
    -pady   => 8,
)->pack(-side => 'top', -fill => 'x');

# Local path bar
my $local_path_frame = $left_pane->Frame(-bg => $C_PANEL)
    ->pack(-side => 'top', -fill => 'x', -padx => 10, -pady => 8);

$local_path_frame->Label(
    -text => 'Path:',
    -bg   => $C_PANEL,
    -fg   => $C_SUBTEXT,
    -font => $F_SMALL,
)->pack(-side => 'left');

$local_path_frame->Entry(
    -textvariable    => \$local_path,
    -width           => 38,
    -bg              => $C_CARD,
    -fg              => $C_TEXT,
    -insertbackground => $C_TEXT,
    -relief          => 'flat',
    -borderwidth     => 1,
    -font            => $F_MONO,
)->pack(-side => 'left', -fill => 'x', -expand => 1, -padx => 8);

make_button($left_pane->Frame(-bg => $C_PANEL)->pack(-side => 'top', -fill => 'x', -padx => 10, -pady => 2),
) if 0;  # placeholder — buttons packed inline below

my $local_btn_bar = $local_path_frame;
make_button($local_btn_bar,
    -text    => 'Browse',
    -command => \&browse_local,
)->pack(-side => 'left', -padx => 2);

make_button($local_btn_bar,
    -text    => 'Go',
    -command => \&refresh_local_list,
)->pack(-side => 'left', -padx => 2);

# Local sort bar
my $local_sort_frame = $left_pane->Frame(-bg => $C_PANEL)
    ->pack(-side => 'top', -fill => 'x', -padx => 10, -pady => 2);

$local_sort_frame->Label(
    -text => 'Sort:',
    -bg   => $C_PANEL,
    -fg   => $C_SUBTEXT,
    -font => $F_SMALL,
)->pack(-side => 'left');

my $local_sort_entry = $local_sort_frame->BrowseEntry(
    -variable  => \$local_sort,
    -state     => 'readonly',
    -width     => 16,
    -choices   => ['Name', 'Date (Newest)', 'Date (Oldest)', 'Size (Largest)', 'Size (Smallest)'],
    -browsecmd => sub { refresh_local_list(); },
    -bg        => $C_CARD,
    -fg        => $C_SORT_FG,
    -font      => $F_NORMAL,
)->pack(-side => 'left', -padx => 8);
browse_entry_fg($local_sort_entry, $C_SORT_FG);

make_button($local_sort_frame,
    -text    => 'Apply',
    -command => \&refresh_local_list,
)->pack(-side => 'left');

# Local listbox
$local_listbox = $left_pane->Scrolled('Listbox',
    -scrollbars       => 'osoe',
    -selectmode       => 'multiple',
    -width            => 50,
    -height           => 22,
    -bg               => $C_CARD,
    -fg               => $C_TEXT,
    -selectbackground => $C_SEL_BG,
    -selectforeground => $C_SEL_FG,
    -relief           => 'flat',
    -borderwidth      => 0,
    -font             => $F_MONO,
    -activestyle      => 'none',
)->pack(-fill => 'both', -expand => 1, -padx => 10, -pady => 6);

$local_listbox->bind('<Double-1>' => sub { navigate_local(); });
$local_listbox->bind('<<ListboxSelect>>' => sub { update_local_info(); });

# Local info bar
$local_info = $left_pane->Label(
    -text    => 'No files selected',
    -bg      => $C_STATUS_BG,
    -fg      => $C_STATUS_FG,
    -font    => $F_SMALL,
    -anchor  => 'w',
    -pady    => 5,
    -padx    => 10,
)->pack(-side => 'bottom', -fill => 'x');

# ---- MIDDLE PANE (Transfer buttons) ----
my $middle_pane = $main_frame->Frame(-bg => $C_BG, -width => 110)
    ->pack(-side => 'left', -fill => 'y', -padx => 4);
$middle_pane->packPropagate(0);

$middle_pane->Frame(-bg => $C_BG, -height => 180)->pack(-side => 'top');

make_button($middle_pane,
    -text    => ">>>\nCopy to\nRemote",
    -width   => 11,
    -height  => 4,
    -bg      => $C_BTN_GREEN,
    -fg      => $C_HDR_FG,
    -activebackground => $C_BTN_GREEN_ACT,
    -command => \&copy_to_remote,
)->pack(-side => 'top', -pady => 10);

make_button($middle_pane,
    -text    => "<<<\nCopy to\nLocal",
    -width   => 11,
    -height  => 4,
    -bg      => $C_BTN_RED,
    -fg      => $C_HDR_FG,
    -activebackground => $C_BTN_RED_ACT,
    -command => \&copy_to_local,
)->pack(-side => 'top', -pady => 10);

$middle_pane->Frame(-bg => $C_BG, -height => 30)->pack(-side => 'top');

make_button($middle_pane,
    -text    => "Select All\nLocal",
    -width   => 11,
    -command => sub { $local_listbox->selectionSet(0, 'end'); update_local_info(); },
)->pack(-side => 'top', -pady => 4);

make_button($middle_pane,
    -text    => "Select All\nRemote",
    -width   => 11,
    -command => sub { $remote_listbox->selectionSet(0, 'end'); update_remote_info(); },
)->pack(-side => 'top', -pady => 4);

# ---- RIGHT PANE (Remote) ----
my $right_pane = $main_frame->Frame(-bg => $C_PANEL, -relief => 'flat', -borderwidth => 0)
    ->pack(-side => 'left', -fill => 'both', -expand => 1, -padx => 6);

$right_pane->Frame(-bg => $C_HDR_REMOTE, -height => 4)->pack(-side => 'top', -fill => 'x');

$right_pane->Label(
    -text   => '  REMOTE FILES',
    -bg     => $C_HDR_REMOTE,
    -fg     => $C_HDR_FG,
    -font   => $F_HEADER,
    -anchor => 'w',
    -pady   => 8,
)->pack(-side => 'top', -fill => 'x');

# Remote path bar
my $remote_path_frame = $right_pane->Frame(-bg => $C_PANEL)
    ->pack(-side => 'top', -fill => 'x', -padx => 10, -pady => 8);

$remote_path_frame->Label(
    -text => 'Path:',
    -bg   => $C_PANEL,
    -fg   => $C_SUBTEXT,
    -font => $F_SMALL,
)->pack(-side => 'left');

$remote_path_frame->Entry(
    -textvariable    => \$remote_path,
    -width           => 38,
    -bg              => $C_CARD,
    -fg              => $C_TEXT,
    -insertbackground => $C_TEXT,
    -relief          => 'flat',
    -borderwidth     => 1,
    -font            => $F_MONO,
)->pack(-side => 'left', -fill => 'x', -expand => 1, -padx => 8);

make_button($remote_path_frame,
    -text    => 'Browse',
    -command => \&browse_remote,
)->pack(-side => 'left', -padx => 2);

make_button($remote_path_frame,
    -text    => 'Go',
    -command => \&refresh_remote_list,
)->pack(-side => 'left', -padx => 2);

# Remote sort bar
my $remote_sort_frame = $right_pane->Frame(-bg => $C_PANEL)
    ->pack(-side => 'top', -fill => 'x', -padx => 10, -pady => 2);

$remote_sort_frame->Label(
    -text => 'Sort:',
    -bg   => $C_PANEL,
    -fg   => $C_SUBTEXT,
    -font => $F_SMALL,
)->pack(-side => 'left');

my $remote_sort_entry = $remote_sort_frame->BrowseEntry(
    -variable  => \$remote_sort,
    -state     => 'readonly',
    -width     => 16,
    -choices   => ['Name', 'Date (Newest)', 'Date (Oldest)', 'Size (Largest)', 'Size (Smallest)'],
    -browsecmd => sub { refresh_remote_list(); },
    -bg        => $C_CARD,
    -fg        => $C_SORT_FG,
    -font      => $F_NORMAL,
)->pack(-side => 'left', -padx => 8);
browse_entry_fg($remote_sort_entry, $C_SORT_FG);

make_button($remote_sort_frame,
    -text    => 'Apply',
    -command => \&refresh_remote_list,
)->pack(-side => 'left');

# Remote listbox
$remote_listbox = $right_pane->Scrolled('Listbox',
    -scrollbars       => 'osoe',
    -selectmode       => 'multiple',
    -width            => 50,
    -height           => 22,
    -bg               => $C_CARD,
    -fg               => $C_TEXT,
    -selectbackground => $C_SEL_BG,
    -selectforeground => $C_SEL_FG,
    -relief           => 'flat',
    -borderwidth      => 0,
    -font             => $F_MONO,
    -activestyle      => 'none',
)->pack(-fill => 'both', -expand => 1, -padx => 10, -pady => 6);

$remote_listbox->bind('<Double-1>' => sub { navigate_remote(); });
$remote_listbox->bind('<<ListboxSelect>>' => sub { update_remote_info(); });

# Remote info bar
$remote_info = $right_pane->Label(
    -text   => 'No files selected',
    -bg     => $C_STATUS_BG,
    -fg     => $C_STATUS_FG,
    -font   => $F_SMALL,
    -anchor => 'w',
    -pady   => 5,
    -padx   => 10,
)->pack(-side => 'bottom', -fill => 'x');

# ---------------------------------------------------------------------------
# Status bar
# ---------------------------------------------------------------------------
$mw->Frame(-bg => $C_BORDER, -height => 1)->pack(-side => 'bottom', -fill => 'x');
my $status_bar = $mw->Frame(-bg => $C_STATUS_BG)
    ->pack(-side => 'bottom', -fill => 'x');

$status_bar->Label(
    -text  => '  STATUS',
    -bg    => $C_STATUS_BG,
    -fg    => $C_HDR_LOCAL,
    -font  => ['Helvetica', 8, 'bold'],
)->pack(-side => 'left', -padx => 8, -pady => 5);

$status_label = $status_bar->Label(
    -text   => 'Ready',
    -bg     => $C_STATUS_BG,
    -fg     => $C_STATUS_OK,
    -font   => $F_SMALL,
    -anchor => 'w',
)->pack(-side => 'left', -fill => 'x', -expand => 1, -pady => 5);

# ---------------------------------------------------------------------------
# Initialize
# ---------------------------------------------------------------------------
refresh_local_list();

# ===========================================================================
# Subroutines
# ===========================================================================

sub is_mounted {
    my ($mount_point) = @_;
    return 0 unless -d $mount_point;
    system('mountpoint', '-q', $mount_point) == 0;
}

sub check_mount_status {
    my $msg = "Mount Status:\n\n";
    for my $name (sort keys %shares) {
        my $mounted = is_mounted($shares{$name}{mount}) ? 'MOUNTED' : 'NOT MOUNTED';
        $msg .= sprintf "%-15s : %s\n", $name, $mounted;
    }
    $mw->messageBox(
        -title   => 'Mount Status',
        -message => $msg,
        -type    => 'OK',
    );
}

sub browse_local {
    my $dir = $mw->chooseDirectory(
        -title      => 'Select Local Directory',
        -initialdir => $local_path,
    );
    if (defined $dir) {
        $local_path = $dir;
        refresh_local_list();
    }
}

sub browse_remote {
    my $start = ($remote_path && -d $remote_path) ? $remote_path : '/home/timmccarthey/Public';
    my $dir = $mw->chooseDirectory(
        -title      => 'Select Remote Directory',
        -initialdir => $start,
    );
    if (defined $dir) {
        $remote_path       = $dir;
        $remote_start_path = $dir;
        refresh_remote_list();
    }
}

sub mount_share {
    my ($name) = @_;
    my $cfg = $shares{$name} or return;
    return if is_mounted($cfg->{mount});

    $status_label->configure(-text => "Mounting $name...", -fg => $C_STATUS_OK);
    $mw->update;

    my $opts = $mount_opts_template;
    $opts =~ s/CREDS/$cfg->{creds}/;

    eval { capture('sudo', 'mount', '-t', 'cifs', $cfg->{share}, $cfg->{mount}, '-o', $opts) };

    if (is_mounted($cfg->{mount})) {
        $status_label->configure(-text => "Mounted: $name", -fg => $C_STATUS_OK);
    } else {
        $status_label->configure(-text => "Mount failed: $name", -fg => '#C05050');
        $mw->messageBox(
            -title   => 'Mount Failed',
            -message => "Could not mount '$name'.\nCheck that the remote machine is online and your credentials are correct.",
            -type    => 'OK',
            -icon    => 'error',
        );
    }
}

sub unmount_share {
    my ($name) = @_;
    my $cfg = $shares{$name} or return;
    return unless is_mounted($cfg->{mount});

    $status_label->configure(-text => "Unmounting $name...", -fg => $C_STATUS_OK);
    $mw->update;

    my $max_retries = 3;
    for my $attempt (1 .. $max_retries) {
        eval { capture('sudo', 'umount', $cfg->{mount}) };
        last unless is_mounted($cfg->{mount});
        sleep 2 if $attempt < $max_retries;
    }

    if (is_mounted($cfg->{mount})) {
        eval { capture('sudo', 'umount', '-l', $cfg->{mount}) };
    }

    if (!is_mounted($cfg->{mount})) {
        $status_label->configure(-text => "Unmounted: $name", -fg => $C_STATUS_OK);
    } else {
        $status_label->configure(-text => "Unmount failed: $name", -fg => '#C05050');
    }
}

sub load_remote_share {
    return unless $selected_share;

    my $mount_point = $shares{$selected_share}{mount};

    unless (is_mounted($mount_point)) {
        mount_share($selected_share);
        return unless is_mounted($mount_point);
    }

    $remote_path       = $mount_point;
    $remote_start_path = $mount_point;
    refresh_remote_list();
}

sub refresh_local_list {
    $local_listbox->delete(0, 'end');

    unless (-d $local_path) {
        $status_label->configure(-text => "Error: Local directory does not exist!", -fg => '#C05050');
        return;
    }

    my $dirs_only = ($local_path eq $local_start_path) ? 1 : 0;
    populate_local_listbox($local_listbox, $local_path, $local_sort, $dirs_only);
    $status_label->configure(-text => "Local sorted by: $local_sort", -fg => $C_STATUS_OK);
    update_local_info();
}

sub refresh_remote_list {
    return unless $remote_path;

    $remote_listbox->delete(0, 'end');
    $status_label->configure(-text => "Loading remote directory...", -fg => $C_STATUS_OK);
    $mw->update;

    warn "DEBUG refresh_remote_list: checking -d $remote_path\n";
    my $t0 = time();
    unless (-d $remote_path) {
        $status_label->configure(-text => "Error: Remote directory does not exist!", -fg => '#C05050');
        warn "DEBUG refresh_remote_list: -d check failed after " . (time()-$t0) . "s\n";
        return;
    }
    warn "DEBUG refresh_remote_list: -d check passed in " . (time()-$t0) . "s\n";

    my $dirs_only = ($remote_start_path && $remote_path eq $remote_start_path) ? 1 : 0;
    populate_local_listbox($remote_listbox, $remote_path, $remote_sort, $dirs_only);
    warn "DEBUG refresh_remote_list: done in " . (time()-$t0) . "s total\n";
    $status_label->configure(-text => "Remote sorted by: $remote_sort", -fg => $C_STATUS_OK);
    update_remote_info();
}

sub populate_local_listbox {
    my ($listbox, $path, $sort_by, $dirs_only) = @_;
    $sort_by ||= 'Name';

    warn "DEBUG populate_local_listbox: opendir $path\n";
    my $t0 = time();
    opendir(my $dh, $path) or do {
        $status_label->configure(-text => "Error: Cannot read directory!", -fg => '#C05050');
        warn "DEBUG populate_local_listbox: opendir failed after " . (time()-$t0) . "s\n";
        return;
    };

    my @entries = readdir($dh);
    closedir($dh);
    warn "DEBUG populate_local_listbox: readdir got " . scalar(@entries) . " entries in " . (time()-$t0) . "s\n";

    $listbox->insert('end', '[..]');

    # Stat each entry once and cache results
    my %stat_cache;
    for my $entry (@entries) {
        next if $entry eq '.' || $entry eq '..';
        my $full = File::Spec->catfile($path, $entry);
        my @st = stat($full);
        $stat_cache{$entry} = { full => $full, mtime => $st[9], size => $st[7], is_dir => -d _ };
    }

    my @dirs  = grep { $stat_cache{$_} && $stat_cache{$_}{is_dir} } keys %stat_cache;
    my @files = $dirs_only ? () : grep { $stat_cache{$_} && !$stat_cache{$_}{is_dir} } keys %stat_cache;
    my @all   = (@dirs, @files);
    warn "DEBUG populate_local_listbox: stat pass done (" . scalar(@dirs) . " dirs, " . scalar(@files) . " files) in " . (time()-$t0) . "s\n";
    my @sorted;

    if ($sort_by eq 'Date (Newest)') {
        @sorted = sort { $stat_cache{$b}{mtime} <=> $stat_cache{$a}{mtime} } @all;
    }
    elsif ($sort_by eq 'Date (Oldest)') {
        @sorted = sort { $stat_cache{$a}{mtime} <=> $stat_cache{$b}{mtime} } @all;
    }
    elsif ($sort_by eq 'Size (Largest)') {
        @sorted = sort { $stat_cache{$b}{size} <=> $stat_cache{$a}{size} } @all;
    }
    elsif ($sort_by eq 'Size (Smallest)') {
        @sorted = sort { $stat_cache{$a}{size} <=> $stat_cache{$b}{size} } @all;
    }
    else {
        @sorted = sort @all;
    }
    warn "DEBUG populate_local_listbox: sort done in " . (time()-$t0) . "s\n";

    foreach my $item (@sorted) {
        if ($stat_cache{$item}{is_dir}) {
            $listbox->insert('end', "[$item]\t  <DIR>");
        } else {
            my $size = format_size($stat_cache{$item}{size} || 0);
            $listbox->insert('end', "$item\t  $size");
        }
    }

    $listbox->see(0);
}

sub navigate_local {
    my @sel = $local_listbox->curselection();
    return unless @sel;

    my $item = extract_name($local_listbox->get($sel[0]));

    if ($item eq '[..]') {
        my $parent = dirname($local_path);
        if ($parent && $parent ne $local_path) {
            $local_path = $parent;
            refresh_local_list();
        }
    }
    elsif ($item =~ /^\[([^\]]+)\]/) {
        my $new_path = File::Spec->catfile($local_path, $1);
        if (-d $new_path) {
            $local_path = $new_path;
            refresh_local_list();
        }
    }
}

sub navigate_remote {
    my @sel = $remote_listbox->curselection();
    return unless @sel;

    my $item = extract_name($remote_listbox->get($sel[0]));

    if ($item eq '[..]') {
        my $parent     = dirname($remote_path);
        my $mount_root = $shares{$selected_share}{mount};
        if ($parent && $parent ne $remote_path && length($parent) >= length($mount_root)) {
            $remote_path = $parent;
            refresh_remote_list();
        }
    }
    elsif ($item =~ /^\[([^\]]+)\]/) {
        my $new_path = File::Spec->catfile($remote_path, $1);
        if (-d $new_path) {
            $remote_path = $new_path;
            refresh_remote_list();
        }
    }
}

sub update_local_info {
    $local_info->configure(-text => get_selection_info($local_listbox, $local_path));
}

sub update_remote_info {
    $remote_info->configure(-text => get_selection_info($remote_listbox, $remote_path));
}

sub get_selection_info {
    my ($listbox, $path) = @_;
    my @sel = $listbox->curselection();
    my ($file_count, $dir_count, $total_size) = (0, 0, 0);

    foreach my $idx (@sel) {
        my $item = extract_name($listbox->get($idx));
        next if $item eq '[..]';
        if ($item =~ /^\[/) {
            $dir_count++;
        } else {
            my $fp = File::Spec->catfile($path, $item);
            if (-f $fp) {
                $file_count++;
                $total_size += -s $fp;
            }
        }
    }

    return 'No files selected' unless $file_count || $dir_count;

    my @parts;
    push @parts, "$file_count file(s)"   if $file_count;
    push @parts, "$dir_count folder(s)"  if $dir_count;
    my $desc = join(' and ', @parts) . ' selected';
    $desc .= '  |  Total: ' . format_size($total_size) if $file_count;
    return $desc;
}

sub extract_name {
    my ($item) = @_;
    $item =~ s/\t.*$//;  # strip everything after the tab separator
    return $item;
}

sub format_size {
    my ($size) = @_;
    my @units = ('B', 'KB', 'MB', 'GB', 'TB');
    my $u = 0;
    while ($size >= 1024 && $u < $#units) { $size /= 1024; $u++ }
    return sprintf("%.2f %s", $size, $units[$u]);
}

sub chunked_copy {
    my ($src, $dest, $pw, $progress_label) = @_;

    warn "DEBUG chunked_copy: $src -> $dest\n";

    open(my $in,  '<:raw', encode_utf8($src))  or die "Cannot open $src: $!";
    open(my $out, '>:raw', encode_utf8($dest)) or die "Cannot open $dest: $!";

    my ($buf, $total_bytes) = ('', 0);
    while (my $bytes = read($in, $buf, 1024 * 1024)) {
        print $out $buf or die "Write failed: $!";
        $total_bytes += $bytes;
        warn "DEBUG  wrote $total_bytes bytes so far\n";
        $pw->update;
    }

    close($in);

    if ($progress_label) {
        $progress_label->configure(-text => 'Flushing: ' . basename($dest));
        $pw->update;
    }

    close($out);
    warn "DEBUG chunked_copy done: $total_bytes bytes total\n";
}

sub copy_directory_recursive {
    my ($src_dir, $dst_dir, $pw, $file_label, $progress_label) = @_;

    make_path($dst_dir) unless -d $dst_dir;

    opendir(my $dh, $src_dir) or die "Cannot read $src_dir: $!";
    my @entries = grep { $_ ne '.' && $_ ne '..' } readdir($dh);
    closedir($dh);

    my ($fc, $dc) = (0, 0);
    foreach my $entry (@entries) {
        my $src  = File::Spec->catfile($src_dir, $entry);
        my $dest = File::Spec->catfile($dst_dir, $entry);
        $file_label->configure(-text => "  $entry");
        $pw->update;
        if (-d $src) {
            my ($f, $d) = copy_directory_recursive($src, $dest, $pw, $file_label, $progress_label);
            $fc += $f;  $dc += $d + 1;
        } else {
            chunked_copy($src, $dest, $pw, $progress_label);
            $fc++;
        }
    }
    return ($fc, $dc);
}

sub copy_to_remote { copy_files($local_listbox,  $local_path,  $remote_path, 'local',  'remote') }
sub copy_to_local  { copy_files($remote_listbox, $remote_path, $local_path,  'remote', 'local')  }

sub copy_files {
    my ($src_lb, $src_path, $dst_path, $src_name, $dst_name) = @_;

    my @sel = $src_lb->curselection();
    unless (@sel) {
        $mw->messageBox(-title => 'No Selection',
            -message => "Please select files from the $src_name pane.", -type => 'OK', -icon => 'warning');
        return;
    }
    unless (-d $dst_path) {
        $mw->messageBox(-title => 'Invalid Destination',
            -message => "Destination directory does not exist:\n$dst_path", -type => 'OK', -icon => 'error');
        return;
    }

    my @items;
    my ($file_count, $dir_count) = (0, 0);
    foreach my $idx (@sel) {
        my $item  = extract_name($src_lb->get($idx));
        next if $item eq '[..]';
        my $clean = ($item =~ /^\[([^\]]+)\]/) ? $1 : $item;
        my $fp    = File::Spec->catfile($src_path, $clean);
        if    (-f $fp) { push @items, { path => $fp, type => 'file', name => $clean }; $file_count++ }
        elsif (-d $fp) { push @items, { path => $fp, type => 'dir',  name => $clean }; $dir_count++  }
    }

    unless (@items) {
        $mw->messageBox(-title => 'No Selection', -message => 'No valid files or directories selected.',
            -type => 'OK', -icon => 'warning');
        return;
    }

    my $arrow    = $src_name eq 'local' ? '>>>' : '<<<';
    my $item_desc = join(' and ',
        ($file_count ? "$file_count file(s)"   : ()),
        ($dir_count  ? "$dir_count folder(s)"  : ()));

    my $confirm = $mw->messageBox(
        -title   => 'Confirm Copy',
        -message => sprintf("Copy %s %s\n\nFrom: %s\nTo:   %s\n\nProceed?",
                            $item_desc, $arrow, $src_path, $dst_path),
        -type    => 'YesNo',
        -icon    => 'question',
    );
    return unless $confirm eq 'Yes';

    # ---------- Progress window ----------
    my $pw = $mw->Toplevel();
    $pw->title("Copying $arrow");
    $pw->geometry("620x220");
    $pw->resizable(0, 0);
    $pw->configure(-bg => $C_BG);

    my $pf = $pw->Frame(-bg => $C_PANEL)->pack(-fill => 'both', -expand => 1, -padx => 20, -pady => 16);

    $pf->Label(-text => "FROM  $src_name", -bg => $C_PANEL, -fg => $C_SUBTEXT, -font => $F_SMALL, -anchor => 'w')
       ->pack(-fill => 'x');
    $pf->Label(-text => "TO    $dst_name", -bg => $C_PANEL, -fg => $C_SUBTEXT, -font => $F_SMALL, -anchor => 'w')
       ->pack(-fill => 'x', -pady => 4);

    my $prog_label = $pf->Label(
        -text   => 'Preparing...',
        -bg     => $C_PANEL,
        -fg     => $C_TEXT,
        -font   => $F_BOLD,
        -anchor => 'w',
    )->pack(-fill => 'x');

    my $file_label = $pf->Label(
        -text   => '',
        -bg     => $C_PANEL,
        -fg     => $C_SUBTEXT,
        -font   => $F_SMALL,
        -anchor => 'w',
    )->pack(-fill => 'x', -pady => 4);

    # Bouncing indeterminate progress bar
    my $track = $pf->Canvas(
        -width              => 560,
        -height             => 28,
        -bg                 => $C_CARD,
        -relief             => 'flat',
        -borderwidth        => 0,
        -highlightthickness => 0,
    )->pack(-pady => 4);

    my $bar_color = $src_name eq 'local' ? '#1F6B3A' : '#8B2020';
    my $bar_w     = 100;
    my $track_w   = 560;
    my $bar_x     = 0;
    my $bar_dir   = 1;
    my $rect      = $track->createRectangle(0, 0, $bar_w, 28, -fill => $bar_color, -outline => '');
    my $anim_id;

    my $animate;
    $animate = sub {
        $bar_x += $bar_dir * 10;
        if ($bar_x + $bar_w >= $track_w) { $bar_x = $track_w - $bar_w; $bar_dir = -1 }
        if ($bar_x <= 0)                 { $bar_x = 0;                  $bar_dir =  1 }
        $track->coords($rect, $bar_x, 0, $bar_x + $bar_w, 28);
        $anim_id = $pw->after(40, $animate);
    };
    $animate->();

    $pw->update;

    # ---------- Copy loop ----------
    $status_label->configure(-text => "  Copy In Progress...", -fg => '#E0A030');
    $mw->update;

    my $flash_on = 1;
    my $flash_id;
    my $flash;
    $flash = sub {
        $flash_on = !$flash_on;
        $status_label->configure(-text => $flash_on ? "  Copy In Progress..." : "");
        $flash_id = $mw->after(500, $flash);
    };
    $flash_id = $mw->after(500, $flash);

    warn "DEBUG copy_files: " . scalar(@items) . " item(s) to copy -> $dst_path\n";
    my ($ok, $fail, @errors) = (0, 0, ());

    for my $i (0 .. $#items) {
        my $item  = $items[$i];
        my $dest  = File::Spec->catfile($dst_path, $item->{name});
        warn "DEBUG item ${\($i+1)}: $item->{type} $item->{path} -> $dest\n";
        my $label = $item->{type} eq 'dir' ? 'folder' : 'file';

        $prog_label->configure(-text => sprintf("Copying %s %d / %d:  %s", $label, $i+1, scalar @items, $item->{name}));
        $file_label->configure(-text => "  $item->{name}");
        $pw->update;
        $mw->update;

        eval {
            if ($item->{type} eq 'file') {
                chunked_copy($item->{path}, $dest, $pw, $prog_label);
            } else {
                copy_directory_recursive($item->{path}, $dest, $pw, $file_label, $prog_label);
            }
            $ok++;
        };
        if ($@) {
            $fail++;
            push @errors, "$item->{name}: $@";
            warn "ERROR: $item->{name}: $@\n";
        }
    }

    $pw->afterCancel($anim_id) if $anim_id;
    $track->coords($rect, 0, 0, $track_w, 28);
    $prog_label->configure(-text => 'Copy complete!');
    $pw->update;
    $pw->destroy;

    my $msg = "Copy completed!\n\nSuccess: $ok\nFailed:  $fail";
    $msg   .= "\n\nErrors:\n" . join("\n", @errors) if @errors;

    $mw->messageBox(
        -title   => 'Copy Complete',
        -message => $msg,
        -type    => 'OK',
        -icon    => $fail > 0 ? 'warning' : 'info',
    );

    $mw->afterCancel($flash_id) if $flash_id;
    $status_label->configure(
        -text => "Copy done — $ok succeeded, $fail failed",
        -fg   => $fail > 0 ? '#C05050' : $C_STATUS_OK,
    );

    if ($src_name eq 'local') { refresh_remote_list() } else { refresh_local_list() }

    unmount_share($selected_share) if $selected_share;
}

# Defer BrowseEntry foreground fixes until after the event loop initializes all widgets.
$mw->after(1, sub {
    browse_entry_fg($share_entry,      $C_SHARE_FG);
    browse_entry_fg($local_sort_entry, $C_SORT_FG);
    browse_entry_fg($remote_sort_entry,$C_SORT_FG);
});

# Auto-mount local shares on startup
$mw->after(1, sub {
    mount_share('tim-movies');
    mount_share('tim-shows');
    refresh_local_list();
});

$mw->protocol('WM_DELETE_WINDOW', sub {
    unmount_share($_) for keys %shares;
    $mw->destroy;
});

MainLoop;
