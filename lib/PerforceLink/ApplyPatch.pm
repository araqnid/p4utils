package PerforceLink::ApplyPatch;
use warnings;
use strict;
use utf8;
use IO::File;
use PerforceLink qw(:p4);
use PerforceLink::StripDiff;

our $tmpdir = $ENV{TMPDIR} || "/tmp";

sub apply_patchfile {
    my $inputfile = shift;
    my $handle = IO::File->new($inputfile) or die "Unable to read $inputfile: $!\n";
    apply_patch($handle, @_);
    $handle->close;
}

sub apply_patch {
    my $inputhandle = shift;
    my %opts = @_;
    my @diffs;
    my $oldfile;
    my $newfile;
    my $prevline;
    my $diffinfo;
    while (<$inputhandle>) {
	chomp;
	if (!$newfile) {
	    if (/^--- (.+)/) {
		$oldfile = $1;
		$oldfile eq '/dev/null' || $oldfile =~ m{^a/} or die "Expected old file to be a/... or /dev/null: $oldfile\n";
		if ($prevline && $prevline =~ m{^(integrate|edit|add|branch|delete) (\S+) (//.+)#(\d+)$}) {
		    $diffinfo = { action => $1, type => $2, depotFile => $3, rev => $4 };
		}
		else {
		    undef $diffinfo;
		}
	    }
	    elsif ($oldfile) {
		if (/^\+\+\+ (.+)/) {
		    $newfile = $1;
		    $newfile eq '/dev/null' || $newfile =~ m{^b/} or die "Expected new file to be b/... or /dev/null: $newfile\n";
		    my $tempfile = "$tmpdir/".sprintf("patch%X%X%X", $$, time, rand()*0x10000);
		    open(OUTPUT, ">$tempfile") or die "Unable to write $tempfile\n";
		    push @diffs, {oldfile => $oldfile, newfile => $newfile, tempfile => $tempfile, extended => $diffinfo};
		    print OUTPUT "--- $oldfile\n";
		    print OUTPUT "+++ $newfile\n";
		}
		else {
		    undef $oldfile;
		}
	    }
	    $prevline = $_;
	}
	else {
	    if (/^[\@ +-]/) {
		print OUTPUT "$_\n";
	    }
	    else {
		close OUTPUT;
		undef $newfile;
		undef $oldfile;
	    }
	}
    }

    print "Testing extracted file patches...\n";
    for my $diffinfo (@diffs) {
	my $path;
	my $action;
	if ($diffinfo->{oldfile} ne '/dev/null') {
	    $path = $diffinfo->{oldfile};
	    $path =~ s{^a/}{} or die "Expected old file to be a/... or /dev/null: $diffinfo->{oldfile}\n";
	    $action = $diffinfo->{newfile} eq '/dev/null' ? 'delete' : 'edit';
	}
	else {
	    $path = $diffinfo->{newfile};
	    $path =~ s{^b/}{} or die "Expected new file to be b/... or /dev/null: $diffinfo->{newfile}\n";
	    $action = 'add';
	}
	print " Considering $path ($action)\n";
	my($opened) = p4_recv("opened", $path);
	if ($opened) {
	    die "Already open: $path\n";
	}
	if ($action eq 'add') {
	    my($fileinfo) = p4_recv("files", $path);
	    if ($fileinfo->{code} eq 'stat') {
		if ($fileinfo->{action} ne 'delete' && $fileinfo->{action} ne 'purge') {
		    die "Patch would try to create new file on top of existing $fileinfo->{depotFile}#$fileinfo->{rev}\n";
		}
	    }
	}
	elsif ($action eq 'edit') {
	    my($fileinfo) = p4_recv("files", $path);
	    if ($fileinfo->{code} eq 'stat') {
		if ($fileinfo->{action} eq 'delete' || $fileinfo->{action} eq 'purge') {
		    die "Patch would try to edit deleted $fileinfo->{depotFile}#$fileinfo->{rev}\n";
		}
	    }
	    else {
		die "Patch would try to edit non-existent $path\n";
	    }
	    if ($fileinfo->{type} =~ /^k[a-z]*text/ || $fileinfo->{type} =~ /^text\+[a-z]*k/) {
		PerforceLink::StripDiff::strip_expansion_hunks_inplace($diffinfo->{tempfile});
	    }
	    $diffinfo->{type} = $fileinfo->{type};
	    $ENV{PATCH_GET} = 0; # Tell patch to ignore Perforce if it supports it
	    my $exitcode = system("patch", "-s", "--dry-run", "-p1", "-i", $diffinfo->{tempfile});
	    if ($exitcode != 0) {
		die "Patch does not apply: $path\n";
	    }
	}
	elsif ($action eq 'delete') {
	    my($fileinfo) = p4_recv("files", $path);
	    if ($fileinfo->{code} eq 'stat') {
		if ($fileinfo->{action} eq 'delete' || $fileinfo->{action} eq 'purge') {
		    die "Patch would try to delete already-deleted $fileinfo->{depotFile}#$fileinfo->{rev}\n";
		}
	    }
	    else {
		die "Patch would try to delete non-existent $path\n";
	    }
	    if ($fileinfo->{type} =~ /^k[a-z]*text/ || $fileinfo->{type} =~ /^text\+[a-z]*k/) {
		PerforceLink::StripDiff::strip_expansion_hunks_inplace($diffinfo->{tempfile});
	    }
	    $diffinfo->{type} = $fileinfo->{type};
	    $ENV{PATCH_GET} = 0; # Tell patch to ignore Perforce if it supports it
	    my $exitcode = system("patch", "-s", "--dry-run", "-p1", "-i", $diffinfo->{tempfile});
	    if ($exitcode != 0) {
		die "Patch does not apply: $path\n";
	    }
	}
	else {
	    die "$action?";
	}
	$diffinfo->{path} = $path;
	$diffinfo->{action} = $action;
    }

    print "Performing patch...\n";
    my @changelist_opt;
    if ($opts{changelist}) {
	@changelist_opt = ("-c", $opts{changelist});
    }

    for my $diffinfo (@diffs) {
	if ($diffinfo->{action} eq 'add') {
	    print " $diffinfo->{path} (add)\n";
	    system "patch", "-p1", "-i", $diffinfo->{tempfile};
	    if ($diffinfo->{extended}->{type}) {
		p4_exec("add", "-t", $diffinfo->{extended}->{type}, @changelist_opt, $diffinfo->{path});
		if ($diffinfo->{extended}->{type} ne $diffinfo->{type}) {
		    print "  set type $diffinfo->{extended}->{type}\n";
		}
	    }
	    else {
		p4_exec("add", @changelist_opt, $diffinfo->{path});
	    }
	}
	elsif ($diffinfo->{action} eq 'edit') {
	    print " $diffinfo->{path} (edit)\n";
	    if ($diffinfo->{extended}->{type}) {
		p4_exec("edit", "-t", $diffinfo->{extended}->{type}, @changelist_opt, $diffinfo->{path});
		if ($diffinfo->{extended}->{type} ne $diffinfo->{type}) {
		    print "  set type $diffinfo->{extended}->{type}\n";
		}
	    }
	    else {
		p4_exec("edit", @changelist_opt, $diffinfo->{path});
	    }
	    system "patch", "-p1", "-i", $diffinfo->{tempfile};
	}
	elsif ($diffinfo->{action} eq 'delete') {
	    print " $diffinfo->{path} (delete)\n";
	    p4_exec("delete", @changelist_opt, $diffinfo->{path});
	}
	unlink($diffinfo->{tempfile});
    }
}

1;
