package PerforceLink::StripDiff;
use warnings;
use strict;
use utf8;

our $tmpdir = $ENV{TMPDIR} || "/tmp";

sub clean {
    my $text = shift;
    do {
	} while ($text =~ s{\$(Id|Revision|Author|Date|Header|File|DateTime|Change): [^\$,]+ \$}{\$$1\$}g);
    return $text;
}

sub interesting_hunk {
    my @removed_lines;
    my @reinserted_lines;
    for (@_) {
	if (/^-(.+)/) {
	    push @removed_lines, clean($1);
	}
	elsif (@removed_lines) {
	    if (/^\+(.+)/) {
		push @reinserted_lines, clean($1);
	    }
	    else {
		if (@removed_lines != @reinserted_lines) {
		    return 1; # Not same number of lines
		}
		for my $i (0..$#removed_lines) {
		    return 1 if ($reinserted_lines[$i] ne $removed_lines[$i]);
		}
		@removed_lines = ();
		@reinserted_lines = ();
	    }
	}
	elsif (/^\+/) {
	    return 1;
	}
    }
    return 0;
}

sub strip_expansion_hunks_inplace($) {
    my $infile = shift;
    my $outfile = sprintf("%s/stripped%X%X%X", $tmpdir, $$, time, rand()*0x10000);
    my $inhandle = IO::File->new($infile) or die "Unable to read $infile: $!\n";
    my $outhandle = IO::File->new(">$outfile") or die "Unable to write $outfile: $!\n";
    strip_expansion_hunks($inhandle, $outhandle);
    $inhandle->close;
    $outhandle->close;
    rename $outfile, $infile or die "Unable to move $outfile back over $infile: $!\n";
}

sub strip_expansion_hunks($$) {
    my $input = shift;
    my $output = shift;
    my @header;
    my @hunk;
    my $state = 'outside';
    while (<$input>) {
	my $oldstate = $state;
	if ($state eq 'outside') {
	    if (m|^--- |) {
		$state = 'header';
		@header = ($_);
	    }
	    else {
		$output->print($_);
	    }
	}
	elsif ($state eq 'header') {
	    if (m|^\@\@|) {
		$state = 'hunk';
		@hunk = ($_);
	    }
	    else {
		push @header, $_;
	    }
	}
	elsif ($state eq 'hunk') {
	    if (m|^\@\@|) {
		if (interesting_hunk(@hunk)) {
		    $output->print(@header);
		    $output->print(@hunk);
		    @header = ();
		}
		@hunk = ($_);
	    }
	    elsif (m|^---|) {
		if (interesting_hunk(@hunk)) {
		    $output->print(@header);
		    $output->print(@hunk);
		    @header = ();
		}
		@hunk = ();
		$state = 'header';
	    }
	    elsif (m|^[ +-]|) {
		push @hunk, $_;
	    }
	    else {
		if (interesting_hunk(@hunk)) {
		    $output->print(@header);
		    $output->print(@hunk);
		    @header = ();
		}
		@hunk = ();
		$state = 'outside';
		print OUTPUT;
	    }
	}
	#print "$oldstate $state : $_\n";
    }

    if ($state eq 'hunk') {
	if (interesting_hunk(@hunk)) {
	    $output->print(@header);
	    $output->print(@hunk);
	}
    }
}


1;
