# common code to test running p4 graph against expected output
use strict;
use IO::Pipe;

sub regress {
    my @our_lines;
    while (<DATA>) {
	push @our_lines, $_;
    }
    print "1..".(scalar(@our_lines)+1)."\n";

    my $pipe = IO::Pipe->new;
    my $pid = fork;
    defined($pid) or die "Can't fork: $!\n";
    if ($pid == 0) {
	$pipe->writer;
	open(STDOUT, ">&=".$pipe->fileno);
	exec "perl", "-Iblib/lib", "blib/script/p4-graph", @_;
    }
    $pipe->reader;
    my $line_number = 1;
    my $their_line;
    while (defined($their_line = $pipe->getline)) {
	my $our_line = $our_lines[$line_number-1];
	$their_line =~ s/\s+$//;
	$our_line =~ s/\s+$//;
	if ($our_line ne $their_line) {
	    print "not ok $line_number - $our_line\n";
	}
	else {
	    print "ok $line_number - $our_line\n";
	}
	++$line_number;
    }
    $pipe->close;
    waitpid($pid, 0);

    if ($line_number == @our_lines + 1) {
	print "ok $line_number - ".scalar(@our_lines)." lines\n";
    }
    else {
	print "not ok $line_number - expected ".scalar(@our_lines)." lines, got $line_number\n";
    }
}

1;
