package PerforceLink::RevisionGraph;
use strict;
use warnings;
use utf8;
use PerforceLink qw(:p4);

sub new {
    my $class = shift;
    return bless({}, $class);
}

sub fetch_filelog {
    my $this = shift;
    my $file = shift;

    my($raw_filelog) = p4_recv("filelog", $file);
    my @filelog;
    for (my $i = 0; $raw_filelog->{"rev$i"}; $i++) {
	my %entry = ( file => $file );
	@entry{qw|rev description changelist client user action filetype digest filesize time|} = map { $raw_filelog->{"$_$i"} } qw|rev desc change client user action type digest fileSize time|;
	push @filelog, \%entry;

	my @aux;
	for (my $j = 0; $raw_filelog->{"how$i,$j"}; $j++) {
	    my %aux_entry;
	    @aux_entry{qw|file how srev erev|} = map { $raw_filelog->{"$_$i,$j"} } qw|file how srev erev|;
	    $aux_entry{srev} =~ /\#(\d+)/ and $aux_entry{start_rev} = $1;
	    $aux_entry{erev} =~ /\#(\d+)/ and $aux_entry{end_rev} = $1;
	    push @aux, \%aux_entry;
	}
	$entry{aux} = \@aux;
    }

    return \@filelog;
}

sub get_filelog {
    my $this = shift;
    my $file = shift;

    $this->{filelogs}->{$file} ||= $this->fetch_filelog($file);
}

sub get_filelog_revision {
    my $this = shift;
    my $file = shift;
    my $revision_number = shift;

    my $filelog = $this->get_filelog($file);
    defined($revision_number) ? [grep { $_->{rev} == $revision_number } @$filelog]->[0] : $filelog->[0];
}

sub get_filelog_previous {
    my $this = shift;
    my $revision = shift;

    my $filelog = $this->get_filelog($revision->{file});
    return [grep { $_->{rev} < $revision->{rev} } @$filelog]->[0];
}

sub get_integration {
    my $this = shift;
    my $revision = shift;

    my($integration) = grep { $_->{how} =~ /(branch|copy|integrate|edit|merge) from|ignored/ } @{$revision->{aux}};
    return $integration;
}

sub callback {
    my $this = shift;
    my $callback = shift;
    my $revision = shift;

    my $integration = $this->get_integration($revision);
    &$callback((map { $revision->{$_} } qw|file rev changelist client user action filetype description time|), $integration ? ($integration->{file}) : (undef));
}

sub get_revision_parents {
    my $this = shift;
    my $revision = shift;

    my @parents;
    my $direct_parent = $this->get_filelog_previous($revision);

    my $integration = $this->get_integration($revision);
    my $alt_parent = $integration && $this->get_filelog_revision($integration->{file}, $integration->{end_rev});

    return grep { defined($_) } ($direct_parent, $alt_parent);
}

sub insert_revision(\@$) {
    my $target = shift;
    my $revision = shift;

    for my $i (0..$#$target) {
	if ($target->[$i]->{changelist} < $revision->{changelist}) {
	    splice @$target, $i, 0, $revision;
	    return;
	}
    }

    push @$target, $revision;
}

sub do_walk {
    my $this = shift;
    my $file = shift;
    my $revision_number = shift;
    my $callback = shift;

    my @stack;
    for (my $revision = $this->get_filelog_revision($file, $revision_number); $revision; $revision = shift @stack) {
	$this->callback($callback, $revision);
	$revision->{seen} = 1;
	my @next = $this->get_revision_parents($revision);
	#use Data::Dumper; die Data::Dumper->new([\@next], [qw|next|])->Dump;
	for (@next) {
	    next if ($_->{seen});
	    insert_revision(@stack, $_);
	    $_->{seen} = 1;
	}
    }
}

1;
