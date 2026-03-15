#!/usr/bin/env perl

use strict;
use warnings;
use Tk;
use Tk::BrowseEntry;
use File::Basename;
use File::Find;
use File::Spec;
use File::Path qw(make_path);

# Configuration from catchAll.pl
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

# Create main window
my $mw = MainWindow->new;
$mw->title("Remote File Copy GUI - Dual Pane");
$mw->geometry("1200x800");

# Variables
my $selected_share = '';
my $local_path = $ENV{HOME};
my $remote_path = '';
my $local_sort = 'Name';

# Declare widgets that will be created later
my ($local_listbox, $remote_listbox, $local_info, $remote_info, $status_label);

# Top frame
my $top_frame = $mw->Frame(-relief => 'raised', -borderwidth => 2)
    ->pack(-side => 'top', -fill => 'x', -padx => 5, -pady => 5);

$top_frame->Label(-text => 'Remote Share:')->pack(-side => 'left', -padx => 5);

$top_frame->BrowseEntry(
    -variable => \$selected_share,
    -state => 'readonly',
    -width => 20,
    -choices => [sort keys %shares],
    -browsecmd => \&load_remote_share
)->pack(-side => 'left', -padx => 5);

$top_frame->Button(
    -text => 'Check Mounts',
    -command => \&check_mount_status
)->pack(-side => 'left', -padx => 5);

$top_frame->Button(
    -text => 'Refresh Both',
    -command => sub { refresh_local_list(); refresh_remote_list(); }
)->pack(-side => 'left', -padx => 5);

# Main dual-pane frame
my $main_frame = $mw->Frame()->pack(-side => 'top', -fill => 'both', -expand => 1, -padx => 5, -pady => 5);

# LEFT PANE - Local files
my $left_pane = $main_frame->Frame(-relief => 'sunken', -borderwidth => 2)
    ->pack(-side => 'left', -fill => 'both', -expand => 1);

$left_pane->Label(
    -text => 'Local Files',
    -bg => 'lightblue',
    -font => ['Arial', 10, 'bold']
)->pack(-side => 'top', -fill => 'x');

# Local path frame
my $local_path_frame = $left_pane->Frame()->pack(-side => 'top', -fill => 'x', -padx => 5, -pady => 5);
$local_path_frame->Label(-text => 'Path:')->pack(-side => 'left');
$local_path_frame->Entry(
    -textvariable => \$local_path,
    -width => 40
)->pack(-side => 'left', -fill => 'x', -expand => 1, -padx => 5);

$local_path_frame->Button(
    -text => 'Browse',
    -command => \&browse_local
)->pack(-side => 'left');

$local_path_frame->Button(
    -text => 'Go',
    -command => \&refresh_local_list
)->pack(-side => 'left', -padx => 2);

# Sort options for local files
my $local_sort_frame = $left_pane->Frame()->pack(-side => 'top', -fill => 'x', -padx => 5, -pady => 2);
$local_sort_frame->Label(-text => 'Sort by:')->pack(-side => 'left');

$local_sort_frame->BrowseEntry(
    -variable => \$local_sort,
    -state => 'readonly',
    -width => 15,
    -choices => ['Name', 'Date (Newest)', 'Date (Oldest)', 'Size (Largest)', 'Size (Smallest)'],
    -listcmd => sub {
        # This gets called when the dropdown is opened
    },
    -browsecmd => sub {
        # This gets called when selection changes
        refresh_local_list();
    }
)->pack(-side => 'left', -padx => 5);

# Add a manual refresh button for sorting
$local_sort_frame->Button(
    -text => 'Apply',
    -command => \&refresh_local_list
)->pack(-side => 'left', -padx => 2);

# Local file list
$local_listbox = $left_pane->Scrolled('Listbox',
    -scrollbars => 'osoe',
    -selectmode => 'multiple',
    -width => 50,
    -height => 25
)->pack(-fill => 'both', -expand => 1, -padx => 5, -pady => 5);

$local_listbox->bind('<Double-1>' => sub { navigate_local(); });

# Local selection info
$local_info = $left_pane->Label(
    -text => 'No files selected',
    -relief => 'sunken',
    -anchor => 'w'
)->pack(-side => 'bottom', -fill => 'x', -padx => 5, -pady => 5);

$local_listbox->bind('<<ListboxSelect>>' => sub { update_local_info(); });

# MIDDLE PANE - Transfer buttons
my $middle_pane = $main_frame->Frame(-width => 100)
    ->pack(-side => 'left', -fill => 'y', -padx => 10);

$middle_pane->packPropagate(0);

# Add some spacing
$middle_pane->Frame(-height => 200)->pack(-side => 'top');

# Copy to remote button
$middle_pane->Button(
    -text => ">>>\nCopy to\nRemote",
    -width => 12,
    -height => 4,
    -bg => 'lightgreen',
    -command => \&copy_to_remote
)->pack(-side => 'top', -pady => 10);

# Copy to local button
$middle_pane->Button(
    -text => "<<<\nCopy to\nLocal",
    -width => 12,
    -height => 4,
    -bg => 'lightcoral',
    -command => \&copy_to_local
)->pack(-side => 'top', -pady => 10);

# Select all buttons
$middle_pane->Frame(-height => 50)->pack(-side => 'top');

$middle_pane->Button(
    -text => "Select All\nLocal",
    -width => 12,
    -command => sub { $local_listbox->selectionSet(0, 'end'); update_local_info(); }
)->pack(-side => 'top', -pady => 5);

$middle_pane->Button(
    -text => "Select All\nRemote",
    -width => 12,
    -command => sub { $remote_listbox->selectionSet(0, 'end'); update_remote_info(); }
)->pack(-side => 'top', -pady => 5);

# RIGHT PANE - Remote files
my $right_pane = $main_frame->Frame(-relief => 'sunken', -borderwidth => 2)
    ->pack(-side => 'left', -fill => 'both', -expand => 1);

$right_pane->Label(
    -text => 'Remote Files',
    -bg => 'lightcoral',
    -font => ['Arial', 10, 'bold']
)->pack(-side => 'top', -fill => 'x');

# Remote path frame
my $remote_path_frame = $right_pane->Frame()->pack(-side => 'top', -fill => 'x', -padx => 5, -pady => 5);
$remote_path_frame->Label(-text => 'Path:')->pack(-side => 'left');
$remote_path_frame->Label(
    -textvariable => \$remote_path,
    -relief => 'sunken',
    -anchor => 'w',
    -width => 40
)->pack(-side => 'left', -fill => 'x', -expand => 1, -padx => 5);

# Remote file list
$remote_listbox = $right_pane->Scrolled('Listbox',
    -scrollbars => 'osoe',
    -selectmode => 'multiple',
    -width => 50,
    -height => 25
)->pack(-fill => 'both', -expand => 1, -padx => 5, -pady => 5);

$remote_listbox->bind('<Double-1>' => sub { navigate_remote(); });

# Remote selection info
$remote_info = $right_pane->Label(
    -text => 'No files selected',
    -relief => 'sunken',
    -anchor => 'w'
)->pack(-side => 'bottom', -fill => 'x', -padx => 5, -pady => 5);

$remote_listbox->bind('<<ListboxSelect>>' => sub { update_remote_info(); });

# Status bar
my $status_frame = $mw->Frame(-relief => 'sunken', -borderwidth => 2)
    ->pack(-side => 'bottom', -fill => 'x');
$status_label = $status_frame->Label(
    -text => 'Ready',
    -anchor => 'w'
)->pack(-side => 'left', -fill => 'x', -expand => 1);

# Initialize local view
refresh_local_list();

# Subroutines

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
        -title => 'Mount Status',
        -message => $msg,
        -type => 'OK'
    );
}

sub browse_local {
    my $dir = $mw->chooseDirectory(
        -title => 'Select Local Directory',
        -initialdir => $local_path
    );
    if (defined $dir) {
        $local_path = $dir;
        refresh_local_list();
    }
}

sub load_remote_share {
    return unless $selected_share;

    my $mount_point = $shares{$selected_share}{mount};

    unless (is_mounted($mount_point)) {
        $status_label->configure(-text => "Warning: $selected_share is not mounted!");
        $mw->messageBox(
            -title => 'Not Mounted',
            -message => "The share '$selected_share' is not currently mounted.\nPlease mount it using catchAll.pl first:\n\n./catchAll.pl mt $selected_share",
            -type => 'OK',
            -icon => 'warning'
        );
        return;
    }

    $remote_path = $mount_point;
    refresh_remote_list();
}

sub refresh_local_list {
    # Clear the listbox
    $local_listbox->delete(0, 'end');

    unless (-d $local_path) {
        $status_label->configure(-text => "Error: Local directory does not exist!");
        return;
    }

    populate_local_listbox($local_listbox, $local_path, $local_sort);
    $status_label->configure(-text => "Loaded and sorted by: $local_sort");
    update_local_info();
}

sub refresh_remote_list {
    return unless $selected_share && $remote_path;

    $remote_listbox->delete(0, 'end');

    unless (-d $remote_path) {
        $status_label->configure(-text => "Error: Remote directory does not exist!");
        return;
    }

    populate_listbox($remote_listbox, $remote_path);
    update_remote_info();
}

sub populate_local_listbox {
    my ($listbox, $path, $sort_by) = @_;
    $sort_by ||= 'Name';

    opendir(my $dh, $path) or do {
        $status_label->configure(-text => "Error: Cannot read directory!");
        return;
    };

    my @entries = readdir($dh);
    closedir($dh);

    # Add parent directory option
    $listbox->insert('end', '[..]');

    # Separate directories and files
    my @dirs = grep { -d File::Spec->catfile($path, $_) && $_ ne '.' && $_ ne '..' } @entries;
    my @files = grep { -f File::Spec->catfile($path, $_) } @entries;

    # Combine dirs and files for unified sorting
    my @all_items = (@dirs, @files);
    my @sorted_items;

    if ($sort_by eq 'Date (Newest)') {
        @sorted_items = sort {
            my $file_a = File::Spec->catfile($path, $a);
            my $file_b = File::Spec->catfile($path, $b);
            my @stat_a = stat($file_a);
            my @stat_b = stat($file_b);
            my $time_a = $stat_a[9] || 0;
            my $time_b = $stat_b[9] || 0;
            $time_b <=> $time_a;
        } @all_items;
    }
    elsif ($sort_by eq 'Date (Oldest)') {
        @sorted_items = sort {
            my $file_a = File::Spec->catfile($path, $a);
            my $file_b = File::Spec->catfile($path, $b);
            my @stat_a = stat($file_a);
            my @stat_b = stat($file_b);
            my $time_a = $stat_a[9] || 0;
            my $time_b = $stat_b[9] || 0;
            $time_a <=> $time_b;
        } @all_items;
    }
    elsif ($sort_by eq 'Size (Largest)') {
        @sorted_items = sort {
            my $file_a = File::Spec->catfile($path, $a);
            my $file_b = File::Spec->catfile($path, $b);
            my @stat_a = stat($file_a);
            my @stat_b = stat($file_b);
            my $size_a = $stat_a[7] || 0;
            my $size_b = $stat_b[7] || 0;
            $size_b <=> $size_a;
        } @all_items;
    }
    elsif ($sort_by eq 'Size (Smallest)') {
        @sorted_items = sort {
            my $file_a = File::Spec->catfile($path, $a);
            my $file_b = File::Spec->catfile($path, $b);
            my @stat_a = stat($file_a);
            my @stat_b = stat($file_b);
            my $size_a = $stat_a[7] || 0;
            my $size_b = $stat_b[7] || 0;
            $size_a <=> $size_b;
        } @all_items;
    }
    else {  # Name
        @sorted_items = sort @all_items;
    }

    # Insert items with proper formatting (directories with brackets)
    foreach my $item (@sorted_items) {
        my $fullpath = File::Spec->catfile($path, $item);
        if (-d $fullpath) {
            $listbox->insert('end', "[$item]");
        } else {
            $listbox->insert('end', $item);
        }
    }

    $listbox->see(0);  # Scroll to top
}

sub populate_listbox {
    my ($listbox, $path) = @_;

    opendir(my $dh, $path) or do {
        $status_label->configure(-text => "Error: Cannot read directory!");
        return;
    };

    my @entries = readdir($dh);
    closedir($dh);

    # Add parent directory option
    $listbox->insert('end', '[..]');

    # Sort: directories first, then files (alphabetically for remote)
    my @dirs = grep { -d File::Spec->catfile($path, $_) && $_ ne '.' && $_ ne '..' } @entries;
    my @files = grep { -f File::Spec->catfile($path, $_) } @entries;

    foreach my $dir (sort @dirs) {
        $listbox->insert('end', "[$dir]");
    }

    foreach my $file (sort @files) {
        $listbox->insert('end', $file);
    }

    $status_label->configure(-text => "Loaded " . (@dirs + @files) . " items from $path");
}

sub navigate_local {
    my @selection = $local_listbox->curselection();
    return unless @selection;

    my $item = $local_listbox->get($selection[0]);

    if ($item eq '[..]') {
        my $parent = dirname($local_path);
        if ($parent && $parent ne $local_path) {
            $local_path = $parent;
            refresh_local_list();
        }
    }
    elsif ($item =~ /^\[(.*)\]$/) {
        my $dir_name = $1;
        my $new_path = File::Spec->catfile($local_path, $dir_name);
        if (-d $new_path) {
            $local_path = $new_path;
            refresh_local_list();
        }
    }
}

sub navigate_remote {
    my @selection = $remote_listbox->curselection();
    return unless @selection;

    my $item = $remote_listbox->get($selection[0]);

    if ($item eq '[..]') {
        my $parent = dirname($remote_path);
        my $mount_root = $shares{$selected_share}{mount};
        if ($parent && $parent ne $remote_path && length($parent) >= length($mount_root)) {
            $remote_path = $parent;
            refresh_remote_list();
        }
    }
    elsif ($item =~ /^\[(.*)\]$/) {
        my $dir_name = $1;
        my $new_path = File::Spec->catfile($remote_path, $dir_name);
        if (-d $new_path) {
            $remote_path = $new_path;
            refresh_remote_list();
        }
    }
}

sub update_local_info {
    my $info = get_selection_info($local_listbox, $local_path);
    $local_info->configure(-text => $info);
}

sub update_remote_info {
    my $info = get_selection_info($remote_listbox, $remote_path);
    $remote_info->configure(-text => $info);
}

sub get_selection_info {
    my ($listbox, $path) = @_;
    my @selection = $listbox->curselection();

    my $file_count = 0;
    my $dir_count  = 0;
    my $total_size = 0;

    foreach my $idx (@selection) {
        my $item = $listbox->get($idx);
        next if $item eq '[..]';

        if ($item =~ /^\[(.*)\]$/) {
            $dir_count++;
        } else {
            my $filepath = File::Spec->catfile($path, $item);
            if (-f $filepath) {
                $file_count++;
                $total_size += -s $filepath;
            }
        }
    }

    if ($file_count == 0 && $dir_count == 0) {
        return 'No files selected';
    }

    my @parts;
    push @parts, "$file_count file(s)" if $file_count > 0;
    push @parts, "$dir_count folder(s)" if $dir_count > 0;
    my $desc = join(' and ', @parts);
    my $size_str = format_size($total_size);
    return "$desc selected" . ($file_count > 0 ? " - Total size: $size_str" : '');
}

sub format_size {
    my ($size) = @_;
    my @units = ('B', 'KB', 'MB', 'GB', 'TB');
    my $unit_idx = 0;

    while ($size >= 1024 && $unit_idx < $#units) {
        $size /= 1024;
        $unit_idx++;
    }

    return sprintf("%.2f %s", $size, $units[$unit_idx]);
}

sub chunked_copy {
    my ($src, $dest, $file_size, $progress_window, $file_label, $progress_canvas, $progress_rect, $progress_text, $base_pct, $file_pct_share) = @_;

    open(my $in,  '<:raw', $src)  or die "Cannot open $src: $!";
    open(my $out, '>:raw', $dest) or die "Cannot open $dest: $!";

    my $chunk_size = 1024 * 1024;  # 1MB chunks
    my $copied     = 0;
    my $buf;

    while (my $bytes = read($in, $buf, $chunk_size)) {
        print $out $buf or die "Write failed: $!";
        $copied += $bytes;

        if ($progress_canvas && $file_size > 0) {
            my $file_progress = $copied / $file_size;
            my $pct       = int($base_pct + $file_progress * $file_pct_share);
            my $bar_width = int($pct / 100 * 500);
            $progress_canvas->coords($progress_rect, 0, 0, $bar_width, 30);
            $progress_canvas->itemconfigure($progress_text, -text => "$pct%");
        }

        $progress_window->update;
    }

    close($in);
    close($out);
}

sub copy_directory_recursive {
    my ($source_dir, $dest_dir, $progress_window, $file_label, $progress_canvas, $progress_rect, $progress_text) = @_;

    # Create destination directory
    make_path($dest_dir) unless -d $dest_dir;

    # First pass: collect all items so we know the total for progress %
    my @all_items;
    find(sub {
        my $name = $File::Find::name;
        return if $name eq $source_dir;
        push @all_items, { src => $name, is_dir => (-d $name) ? 1 : 0 };
    }, $source_dir);

    my $total      = scalar @all_items;
    my $done       = 0;
    my $file_count = 0;
    my $dir_count  = 0;

    # Second pass: copy one item at a time, updating UI after each
    foreach my $item (@all_items) {
        my $source_file  = $item->{src};
        my $relative     = File::Spec->abs2rel($source_file, $source_dir);
        my $dest_file    = File::Spec->catfile($dest_dir, $relative);

        $file_label->configure(-text => "  $relative");
        $progress_window->update;

        if ($item->{is_dir}) {
            make_path($dest_file) unless -d $dest_file;
            $dir_count++;
            $done++;
        } else {
            my $file_size    = -s $source_file || 0;
            my $base_pct     = $total > 0 ? int(($done / $total) * 100) : 0;
            my $file_pct_share = $total > 0 ? (1 / $total) * 100 : 100;

            chunked_copy($source_file, $dest_file, $file_size,
                         $progress_window, $file_label,
                         $progress_canvas, $progress_rect, $progress_text,
                         $base_pct, $file_pct_share);
            $file_count++;
            $done++;
        }

        if ($progress_canvas && $total > 0) {
            my $pct       = int(($done / $total) * 100);
            my $bar_width = int(($done / $total) * 500);
            $progress_canvas->coords($progress_rect, 0, 0, $bar_width, 30);
            $progress_canvas->itemconfigure($progress_text, -text => "$pct%");
        }

        $progress_window->update;
    }

    return ($file_count, $dir_count);
}

sub copy_to_remote {
    copy_files($local_listbox, $local_path, $remote_path, 'local', 'remote');
}

sub copy_to_local {
    copy_files($remote_listbox, $remote_path, $local_path, 'remote', 'local');
}

sub copy_files {
    my ($source_listbox, $source_path, $dest_path, $source_name, $dest_name) = @_;

    my @selection = $source_listbox->curselection();

    unless (@selection) {
        $mw->messageBox(
            -title => 'No Selection',
            -message => "Please select files from the $source_name pane to copy.",
            -type => 'OK',
            -icon => 'warning'
        );
        return;
    }

    unless (-d $dest_path) {
        $mw->messageBox(
            -title => 'Invalid Destination',
            -message => "Destination directory does not exist:\n$dest_path",
            -type => 'OK',
            -icon => 'error'
        );
        return;
    }

    my @items_to_copy;
    my $file_count = 0;
    my $dir_count = 0;

    foreach my $idx (@selection) {
        my $item = $source_listbox->get($idx);
        next if $item eq '[..]';  # Skip parent directory entry

        # Remove brackets from directory names
        my $clean_name = $item;
        if ($item =~ /^\[(.*)\]$/) {
            $clean_name = $1;
        }

        my $filepath = File::Spec->catfile($source_path, $clean_name);
        if (-f $filepath) {
            push @items_to_copy, { path => $filepath, type => 'file', name => $clean_name };
            $file_count++;
        } elsif (-d $filepath) {
            push @items_to_copy, { path => $filepath, type => 'dir', name => $clean_name };
            $dir_count++;
        }
    }

    unless (@items_to_copy) {
        $mw->messageBox(
            -title => 'No Selection',
            -message => 'No valid files or directories selected.',
            -type => 'OK',
            -icon => 'warning'
        );
        return;
    }

    # Confirm copy operation
    my $arrow = $source_name eq 'local' ? '>>>' : '<<<';
    my $item_desc = '';
    $item_desc .= "$file_count file(s)" if $file_count > 0;
    $item_desc .= " and " if $file_count > 0 && $dir_count > 0;
    $item_desc .= "$dir_count folder(s)" if $dir_count > 0;

    my $confirm = $mw->messageBox(
        -title => 'Confirm Copy',
        -message => sprintf("Copy %s %s\n\nFrom: %s\nTo: %s\n\nProceed?",
                           $item_desc, $arrow, $source_path, $dest_path),
        -type => 'YesNo',
        -icon => 'question'
    );

    return unless $confirm eq 'Yes';

    # Create progress window
    my $progress_window = $mw->Toplevel();
    $progress_window->title("Copying Files $arrow");
    $progress_window->geometry("550x180");
    $progress_window->resizable(0, 0);

    my $progress_frame = $progress_window->Frame()->pack(-fill => 'both', -expand => 1, -padx => 20, -pady => 20);

    $progress_frame->Label(
        -text => "From: $source_name",
        -anchor => 'w',
        -fg => 'blue'
    )->pack(-fill => 'x', -pady => 2);

    $progress_frame->Label(
        -text => "To: $dest_name",
        -anchor => 'w',
        -fg => 'darkgreen'
    )->pack(-fill => 'x', -pady => 2);

    my $progress_label = $progress_frame->Label(
        -text => 'Preparing to copy...',
        -anchor => 'w',
        -font => ['Arial', 9, 'bold']
    )->pack(-fill => 'x', -pady => 5);

    my $file_label = $progress_frame->Label(
        -text => '',
        -anchor => 'w',
        -fg => 'blue'
    )->pack(-fill => 'x', -pady => 5);

    my $progress_canvas = $progress_frame->Canvas(
        -width => 500,
        -height => 30,
        -bg => 'white',
        -relief => 'sunken',
        -borderwidth => 2
    )->pack(-pady => 10);

    my $progress_rect = $progress_canvas->createRectangle(
        0, 0, 0, 30,
        -fill => ($source_name eq 'local' ? 'green' : 'red'),
        -outline => ''
    );

    my $progress_text = $progress_canvas->createText(
        250, 15,
        -text => '0%',
        -font => ['Arial', 10, 'bold']
    );

    # Perform the copy
    my $success_count = 0;
    my $fail_count = 0;
    my @errors;
    my $total_items = scalar(@items_to_copy);

    foreach my $i (0 .. $#items_to_copy) {
        my $item = $items_to_copy[$i];
        my $source = $item->{path};
        my $item_name = $item->{name};
        my $dest = File::Spec->catfile($dest_path, $item_name);

        # Update progress
        my $percent = int(($i / $total_items) * 100);
        my $bar_width = int(($i / $total_items) * 500);

        my $type_label = $item->{type} eq 'dir' ? 'folder' : 'file';
        $progress_label->configure(-text => sprintf("Copying %s %d of %d...", $type_label, $i + 1, $total_items));
        $file_label->configure(-text => $item_name);
        $progress_canvas->coords($progress_rect, 0, 0, $bar_width, 30);
        $progress_canvas->itemconfigure($progress_text, -text => "$percent%");
        $status_label->configure(-text => "Copying $item_name...");
        $progress_window->update;

        eval {
            if ($item->{type} eq 'file') {
                my $file_size = -s $source || 0;
                chunked_copy($source, $dest, $file_size,
                             $progress_window, $file_label,
                             $progress_canvas, $progress_rect, $progress_text,
                             $percent, 100 - $percent);
            } elsif ($item->{type} eq 'dir') {
                my ($files, $dirs) = copy_directory_recursive($source, $dest, $progress_window, $file_label, $progress_canvas, $progress_rect, $progress_text);
            }
            $success_count++;
        };
        if ($@) {
            $fail_count++;
            my $error = $@;
            warn "ERROR: Failed to copy $item_name: $error\n";
            push @errors, "$item_name: $error";
        }
    }

    # Final progress update
    $progress_canvas->coords($progress_rect, 0, 0, 500, 30);
    $progress_canvas->itemconfigure($progress_text, -text => "100%");
    $progress_label->configure(-text => "Copy complete!");
    $progress_window->update;

    # Close progress window after a brief pause
    $progress_window->after(1000, sub { $progress_window->destroy; });

    # Show results
    my $msg = "Copy completed!\n\n";
    $msg .= "Success: $success_count file(s)\n";
    $msg .= "Failed: $fail_count file(s)\n";

    if (@errors) {
        $msg .= "\nErrors:\n" . join("\n", @errors);
    }

    $mw->messageBox(
        -title => 'Copy Complete',
        -message => $msg,
        -type => 'OK',
        -icon => $fail_count > 0 ? 'warning' : 'info'
    );

    $status_label->configure(-text => "Copy completed: $success_count success, $fail_count failed");

    # Refresh destination pane
    if ($source_name eq 'local') {
        refresh_remote_list();
    } else {
        refresh_local_list();
    }
}

# Start the GUI
MainLoop;
