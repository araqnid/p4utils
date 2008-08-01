# common code to test running p4 graph against expected output
use strict;
use IO::Pipe;
use PerforceLink::RevisionGraph;
use Test::Builder;

sub regress {
    my $filespec = shift;
    my($file, $revision) = split(/\#/, $filespec);
    my $test = Test::Builder->new;
    my @our_lines;
    while (<DATA>) {
	chomp;
	s/^.*\[/\[/ or next; # TEMPORARY
	push @our_lines, $_;
    }
    $test->plan(tests => scalar @our_lines);

    my $line_number = 1;
    PerforceLink::RevisionGraph->new->do_walk($file, $revision, sub {
	my($depotfile, $filerev, $changelist, $client, $user, $action, $filetype, $message) = @_;
	my $their_line = "[$user] $depotfile #$filerev $action\@$changelist $message";
	$their_line =~ s/\s+$//;
	my $our_line = $our_lines[$line_number - 1];
	if ($line_number <= @our_lines) {
	    $test->cmp_ok($their_line, 'eq', $our_line, "line $line_number");
	}
	$line_number++;
    });

    for my $i ($line_number..scalar @our_lines) {
	$test->cmp_ok(undef, 'eq', $our_lines[$i], "line $line_number");
    }
}

1;
