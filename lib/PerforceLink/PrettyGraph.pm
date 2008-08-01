package PerforceLink::PrettyGraph;
use strict;
use warnings;
use utf8;
use PerforceLink::RevisionGraph;

sub new {
    my $class = shift;
    return bless({ walker => PerforceLink::RevisionGraph->new }, $class);
}

sub find_branch {
    my $this = shift;
    my $file = shift;

    for my $i (0..$#{$this->{branch_file}}) {
	return $i if ($this->{branch_file}->[$i] eq $file);
    }

    return -1;
}

sub draw_line {
    my $this = shift;
    my $from_branchidx = shift;
    my $to_branchidx = shift;
    my $callback = shift;

    my $dir = $to_branchidx < $from_branchidx ? -1 : 1;
    for (my $pos = $from_branchidx; $pos != $to_branchidx; $pos += $dir) {
	&$callback(join('', map { ($this->{branch_live}->[$_] ? '|' : ' ').($_ == $pos && $dir > 0 ? '\\' : $_ == ($pos-1) && $dir < 0 ? '/' : ' ') } 0..$#{$this->{branch_file}}));
	if (abs($pos - $to_branchidx) > 1) {
	    &$callback(join(' ', map { $_ == ($pos+$dir) ? ($dir > 0 ? '\\' : '/') : $this->{branch_live}->[$_] ? '|' : ' ' } 0..$#{$this->{branch_file}}));
	}
    }
}

sub print_revision {
    my $this = shift;
    my $callback = shift;
    my($file, $rev, $changelist, $client, $user, $action, $filetype, $description, $time, $aux_file) = @_;

    my $branchidx = $this->find_branch($file);

    if ($branchidx < 0) {
	# New branch
	push @{$this->{branch_file}}, $file;
	$branchidx = $#{$this->{branch_file}};
	$this->{branch_live}->[$branchidx] = 1;
    }

    &$callback(join(' ', map { $_ == $branchidx ? $action eq 'delete' ? 'X' : '*' : $this->{branch_live}->[$_] ? '|' : ' ' } 0..$#{$this->{branch_file}}), @_);

    if ($action eq 'branch') {
	my $from_branchidx = $this->find_branch($aux_file);
	if ($from_branchidx < 0) {
	    # Replace this file with where it was branched from
	    $this->{branch_file}->[$branchidx] = $aux_file;
	} else {
	    $this->{branch_live}->[$branchidx] = 0;
	    $this->draw_line($branchidx, $from_branchidx, $callback);
	}
    }
    elsif ($action eq 'integrate') {
	if ($aux_file) {
	    my $from_branchidx = $this->find_branch($aux_file);
	    if ($from_branchidx < 0) {
		push @{$this->{branch_file}}, $aux_file;
		$from_branchidx = $#{$this->{branch_file}};
		$this->draw_line($branchidx, $from_branchidx, $callback);
		$this->{branch_live}->[$from_branchidx] = 1;
	    }
	    else {
		$this->draw_line($branchidx, $from_branchidx, $callback);
	    }
	}
	else {
	    die "No aux_file for integrate action $file#$rev\n";
	}
    }
    elsif ($action eq 'add') {
	$this->{branch_live}->[$branchidx] = 0;
    }

    while (@{$this->{branch_file}} && !$this->{branch_live}->[$#{$this->{branch_file}}]) {
	pop @{$this->{branch_file}};
    }
}

sub print_graph {
    my $this = shift;
    my $file = shift;
    my $revision_number = shift;
    my $callback = shift;

    $this->{branch_file} = [];
    $this->{branch_live} = [];
    $this->{walker}->do_walk($file, $revision_number, sub { $this->print_revision($callback, @_) });
}

1;
