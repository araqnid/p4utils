package PerforceLink;
use strict;
use warnings;
use utf8;
use Exporter;
use Carp;
use Encode;
use POSIX;
use IO::Pipe;
use vars qw(@ISA @EXPORT_OK $DEBUG %EXPORT_TAGS);

@ISA = qw(Exporter);
@EXPORT_OK = qw(p4_recv p4_recv_raw p4_send p4_exec marshal unmarshal);
%EXPORT_TAGS = (p4 => [qw|p4_recv p4_recv_raw p4_send p4_exec|], marshal => [qw|marshal unmarshal|]);
$DEBUG = $ENV{P4LINK_DEBUG};

sub decode_exitstatus($) {
    my $status = shift;
    if (WIFEXITED($status)) {
	if (WEXITSTATUS($status) == 0) {
	    return "DONE";
	}
	return "EXITED<".WEXITSTATUS($status).">";
    }
    elsif (WIFSIGNALED($status)) {
	return "DIED<".WTERMSIG($status).">";
    }
    elsif (WIFSTOPPED($status)) {
	return "STOPPED<".WSTOPSIG($status).">";
    }
    else {
	return "FAILED_UNKNOWN<".$status.">";
    }
}

sub marshal($$) {
    _marshal(@_);
}

sub _marshal {
    my $fh = shift;
    my $data = shift;
    if (!defined $data) {
	$fh->print('0');
    }
    elsif (ref $data eq 'HASH') {
	# Dictionary- marshal as key-value pairs followed by undef
	$fh->print('{');
	while(my($key, $value) = each %$data) {
	    _marshal($fh, $key);
	    _marshal($fh, $value);
	}
	$fh->print('0');
    }
    elsif (ref $data eq 'ARRAY') {
	croak "Array not handled\n";
    }
    else {
	if (0) {
	    my $encoded = encode("utf-8", $data);
	    $fh->print('u');
	    marshal_int32($fh, length($encoded));
	    $fh->print($encoded);
	}
	else {
	    my $encoded = encode("utf-8", $data);
	    $fh->print('s');
	    marshal_int32($fh, length($encoded));
	    $fh->print($encoded);
	}
    }
}

sub marshal_int32 {
    my $fh = shift;
    my $data = shift;
    $fh->print(pack("c4", $data & 0xff, ($data & 0xff00) >> 8, ($data & 0xff0000) >> 16, ($data & 0xff000000) >> 24));
}


sub unmarshal($) {
    _unmarshal(shift);
}

sub _unmarshal {
    my $fh = shift;
    my $type = getc $fh;
    if ($type eq 's') {
	# String
	my $len = _unmarshal_int32($fh);
	my $str = '';
	for my $i (1..$len) {
	    $str .= getc $fh;
	}
	return $str;
    }
    elsif ($type eq 'u') {
	# Unicode string
	my $len = _unmarshal_int32($fh);
	my $str = '';
	for my $i (1..$len) {
	    $str .= getc $fh;
	}
	return decode("utf-8", $str);
    }
    elsif ($type eq 'i') {
	my $val = _unmarshal_int32($fh);
	return $val;
    }
    elsif ($type eq '{') {
	my %dict;
	
	while (!eof $fh) {
	    my $key = _unmarshal($fh);
	    last if (!defined $key);
	    my $value = _unmarshal($fh);
	    $dict{$key} = $value;
	}

	return \%dict;
    }
    elsif ($type eq '0') {
	return undef;
    }
    else {
	confess "Unsupported type: $type";
    }
}

sub _unmarshal_int32 {
    my $fh = shift;
    my $v = ord(getc $fh);
    $v |= ord(getc $fh) << 8;
    $v |= ord(getc $fh) << 16;
    $v |= ord(getc $fh) << 24;
    return $v;
}

sub p4_exec {
    my($subcommand, @args) = @_;
    my $pipe = IO::Pipe->new;
    my $pid = fork;
    die "fork: $!\n" unless (defined $pid);
    if ($pid == 0) {
	# Child process
	$pipe->writer;
	open(STDOUT, ">&".$pipe->fileno) or die "Unable to reopen stdout to pipe: $!\n";
	exec "p4", $subcommand, @args or die "Unable to exec p4: $!\n";
    }
    $pipe->reader;
    print STDERR "** $pid: EXEC p4 $subcommand @args\n" if ($DEBUG);
    my $line;
    my $output = '';
    while (defined($line = $pipe->getline)) {
	$line =~ s/\r?\n$//;
	print "p4 $subcommand: $line\n";
	$output .= "$line\n";
    }
    $pipe->close;
    waitpid $pid, 0;
    my $status = $?;
    
    if ($status == 0) {
	print STDERR "** $pid: DONE p4 $subcommand @args\n" if ($DEBUG);
    }
    else {
	print STDERR "** $pid: ".decode_exitstatus($status)." p4 $subcommand @args\n" if ($DEBUG);
	die "p4 $subcommand failed\n";
    }

    return $output;
}

sub p4_recv {
    my($subcommand, @args) = @_;
    my $pipe = IO::Pipe->new;
    my $pid = fork;
    die "fork: $!\n" unless (defined $pid);
    if ($pid == 0) {
	# Child process
	$pipe->writer;
	open(STDOUT, ">&".$pipe->fileno) or die "Unable to reopen stdout to pipe: $!\n";
	exec "p4", "-G", $subcommand, @args or die "Unable to exec p4: $!\n";
    }
    $pipe->reader;
    print STDERR "** $pid: RECV p4 $subcommand @args\n" if ($DEBUG);
    my @objects;
    if ($subcommand eq 'diff') {
	while (!$pipe->eof) {
	    push @objects, unmarshal($pipe);
	    my $line;
	    my $output = '';
	    # FIXME need to be able to somehow detect the end of the diff output
	    while (defined($line = $pipe->getline)) {
		$output .= $line;
	    }
	    push @objects, $output;
	}
    }
    else {
	while (!$pipe->eof) {
	    push @objects, unmarshal($pipe);
	}
    }
    $pipe->close;
    waitpid $pid, 0;
    my $status = $?;
    
    if ($status == 0) {
	print STDERR "** $pid: DONE p4 $subcommand @args\n" if ($DEBUG);
    }
    else {
	print STDERR "** $pid: ".decode_exitstatus($status)." p4 $subcommand @args\n" if ($DEBUG);
	croak "Getting data from p4 $subcommand failed";
    }

    if (wantarray) {
	return @objects;
    }
    else {
	return $objects[0];
    }
}

sub p4_recv_raw {
    my($subcommand, @args) = @_;
    my $pipe = IO::Pipe->new;
    my $pid = fork;
    die "fork: $!\n" unless (defined $pid);
    if ($pid == 0) {
	# Child process
	$pipe->writer;
	open(STDOUT, ">&".$pipe->fileno) or die "Unable to reopen stdout to pipe: $!\n";
	exec "p4", $subcommand, @args or die "Unable to exec p4: $!\n";
    }
    $pipe->reader;
    print STDERR "** $pid: RECV-RAW p4 $subcommand @args\n" if ($DEBUG);
    my $output = '';
    my $buffer;
    my $nbytes;
    while ($nbytes = $pipe->sysread($buffer, 16384)) {
	$output .= $buffer;
    }
    $pipe->close;
    waitpid $pid, 0;
    my $status = $?;

    if ($status == 0) {
	print STDERR "** $pid: DONE p4 $subcommand @args\n" if ($DEBUG);
    }
    else {
	print STDERR "** $pid: ".decode_exitstatus($status)." p4 $subcommand @args\n" if ($DEBUG);
	croak "Getting data from p4 $subcommand failed";
    }

    return $output;
}

sub p4_send($$) {
    my($subcommand, $data) = @_;
    my $send_pipe = IO::Pipe->new;
    my $recv_pipe = IO::Pipe->new;
    my $pid = fork;
    die "fork: $!\n" unless (defined $pid);
    if ($pid == 0) {
	# Child process
	$send_pipe->reader;
	$recv_pipe->writer;
	open(STDIN, "<&".$send_pipe->fileno) or die "Unable to reopen stdin to pipe: $!\n";
	open(STDOUT, ">&".$recv_pipe->fileno) or die "Unable to reopen stdout to pipe: $!\n";
	exec "p4", "-G", $subcommand, "-i" or die "Unable to exec p4: $!\n";
    }
    $send_pipe->writer;
    $recv_pipe->reader;
    print STDERR "** $pid: SEND p4 $subcommand -i\n" if ($DEBUG);
    marshal($send_pipe, $data);
    $send_pipe->close;
    my @objects;
    while (!$recv_pipe->eof) {
	push @objects, unmarshal($recv_pipe);
    }
    $recv_pipe->close;
    waitpid $pid, 0;
    my $status = $?;
    
    if ($status == 0) {
	print STDERR "** $pid: DONE p4 $subcommand -i\n" if ($DEBUG);
    }
    else {
	print STDERR "** $pid: ".decode_exitstatus($status)." p4 $subcommand -i\n" if ($DEBUG);
	croak "sending data to p4 $subcommand failed: ".Data::Dumper->new([\@objects], [qw|objects|])->Terse(1)->Indent(0)->Dump;
    }

    if (wantarray) {
	return @objects;
    }
    else {
	return $objects[0];
    }
}

1;
