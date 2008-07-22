package PerforceLink::Git;
use strict;
use warnings;
use utf8;
use IO::Pipe;
use IO::File;
use IO::Wrap;
use Git;
use Error qw(:try);
use Data::Dumper;
use Cwd qw(abs_path);
use Carp;
use Encode;
use Date::Format;
use PerforceLink qw(:p4);
# p4 help filetypes
use constant FILETYPE_ALIASES => {
    "ctext" => ["text", "C"],
    "cxtext" => ["text", "Cx"],
    "ktext" => ["text", "k"],
    "kxtext" => ["text", "kx"],
    "ltext" => ["text", "F"],
    "tempobj" => ["binary", "Sw"],
    "ubinary" => ["binary", "F"],
    "uresource" => ["resource", "F"],
    "uxbinary" => ["binary", "Fx"],
    "xbinary" => ["binary", "x"],
    "xltext" => ["text", "Fx"],
    "xtempobj" => ["binary", "Swx"],
    "xtext" => ["text", "x"],
    "xunicode" => ["unicode", "x"],
    "xutf16" => ["utf16", "x"],
};
use base qw(Class::Accessor);
__PACKAGE__->mk_accessors(qw(git_repo p4base branchspecs remotename debug max_changes fast_scan tag_changelists output_file checkpoint_commits checkpoint_interval checkpoint_bytes grafts change_charset));

sub new {
    my $pkg = shift;
    my %p = @_;
    my $this = $pkg->SUPER::new(\%p);
    $this->git_repo(Git->repository(Directory => $p{repo_dir})) if ($p{repo_dir});
    return $this;
}

sub get_p4user($) {
    my $userid = shift;
    our %usertab;
    if (!%usertab) {
	for (p4_recv("users")) {
	    $usertab{$_->{User}} = $_;
	}
    }
    return $usertab{$userid} || { User => $userid, Email => $userid, FullName => $userid };
}

sub decode_p4_filetype($) {
    my $filetype = shift;
    my $aliased = FILETYPE_ALIASES->{$filetype};
    return @$aliased if ($aliased);
    my($basetype, $mods) = split(/\+/, $filetype, 2);
    $mods ||= '';
    return ($basetype, $mods);
}

sub convertpath($$$) {
    my $dirname = shift;
    my $input_pattern = shift;
    my $output_pattern = shift;

    # Trivial cases
    return $output_pattern if ($input_pattern !~ /\*/ && $input_pattern eq $dirname);
    return $dirname if ($input_pattern eq $output_pattern);

    my $input_re = $input_pattern;
    $input_re =~ s{\*}{(.*)};

    my $output_string = $output_pattern;
    my $index = 1;
    $output_string =~ s{\*}{"\$".($index++)}ge;

    eval "\$dirname =~ s{$input_re}{$output_string}";

    return $dirname;
}

sub decode_p4path {
    my $this = shift;
    my $p4path = shift;

    # Ignore files outside our base completely
    return if (length($p4path) < length($this->p4base) || substr($p4path, 0, length($this->p4base)) ne $this->p4base);

    my $residual = substr($p4path, length($this->p4base) + 1);

    return ("master", $residual) if (!@{$this->branchspecs});

    for (@{$this->branchspecs}) {
	my($subdir_pattern, $branch_pattern) = @$_;
	my $input_re = $subdir_pattern;
	$input_re =~ s{\*}{([^/]*)};
	$input_re = "^$input_re/";

	my $output_string = $branch_pattern;
	my $index = 1;
	$output_string =~ s{\*}{"\$".($index++)}ge;

	if ($residual =~ s{$input_re}{}) {
	    $output_string = eval "qq{$output_string}";
	    return ($output_string, $residual);
	    die Data::Dumper->new([$residual, $subdir_pattern, $branch_pattern, $input_re, $output_string], [qw|residual subdir_pattern branch_patern input_re output_string|])->Dump;
	}
    }

    return (undef, $residual);
}

sub accumulate_changes {
    my $this = shift;
    my $since = shift;

    my @p4changes;
    if ($this->fast_scan) {
	@p4changes = p4_recv("changes", "-l", "-t", $this->p4base."/...".($since ? join("", '@', $since+1, ",#head") : ""));
    }
    else {
	my @paths;

	if (!@{$this->branchspecs}) {
	    @paths = ($this->p4base);
	}
	else {
	    for (@{$this->branchspecs}) {
		my($subdir_pattern, $branch) = @$_;
		push @paths, map { $_->{dir} } p4_recv("dirs", $this->p4base."/$subdir_pattern");
	    }
	}

	for my $path (@paths) {
	    if ($since) {
		my($old_change) = p4_recv("changes", "-m", "1", "$path/...\@$since");
		if (!$old_change) {
		    push @p4changes, p4_recv("changes", "-l", "-t", "$path/...");
		}
		else {
		    push @p4changes, p4_recv("changes", "-l", "-t", "$path/...".($since ? join("", '@', $since+1, ",#head") : ""));
		}
	    }
	    else {
		push @p4changes, p4_recv("changes", "-l", "-t", "$path/...");
	    }
	}
    }

    return sort { $a->{id} <=> $b->{id} } map {
	{ user => get_p4user($_->{user}),
	  id => $_->{change},
	  subject => ([grep { $_ ne '' } split(/\n/, $this->to_utf8($_->{desc}))]->[0] || ''),
	  desc => $_->{desc},
	  time => $_->{time} } } @p4changes;
}

sub known_branches {
    my $this = shift;
    return () unless ($this->git_repo);
    my $remotename = $this->remotename;
    try {
	return map { $_->[1] } grep { $_->[1] =~ s|^refs/remotes/$remotename/|| } map { [split(/\s+/)] } split(/\n/, $this->git_repo->command("show-ref"));
    } catch Git::Error::Command with {
	my $e = shift;
	return () if ($e->value == 1);
	throw $e;
    }
}

sub fetch_p4_changes {
    my $this = shift;
    my $last_checkpoint = [time, 0, 0];
    my $data_sent = 0;
    my $chgcounter = 0;

    my($fast_import_ctx, $fast_import_pipe);

    my $last_change;
    my %seen_branch;
    my @known_branches = $this->known_branches;
    my %branch_exists = map { ($_, 1) } @known_branches;
    my %branch_grafts;
    if ($this->grafts) {
	open(GRAFTS, $this->grafts) or die "Unable to read ".$this->grafts.": $!\n";
	while (<GRAFTS>) {
	    my($branch, $changelist) = split(/\s+/);
	    $branch_grafts{$branch} = $changelist;
	}
	close(GRAFTS);
    }

    my $marksfile;
    my $since_changelist;
    if ($this->git_repo) {
	my $marksdir = $this->git_repo->repo_path."/marks";
	(-d $marksdir) || mkdir $marksdir, 0775 or die "Unable to create $marksdir: $!\n";
	$marksfile = join("/", $marksdir, $this->remotename);
	if (-f $marksfile) {
	    open(MARKS, $marksfile) or die "Unable to read $marksfile: $!\n";
	    while (<MARKS>) {
		my($mark, $commit) = split(/\s+/);
		$mark =~ /^:(\d+)/ or die "Invalid fast-import mark in $marksfile: $mark";
		$since_changelist = $1;
	    }
	    close(MARKS);
	}
    }

    if ($this->output_file) {
	if ($this->output_file ne '-') {
	    open(OUTPUT, ">".$this->output_file) or die "Unable to write ".$this->output_file.": $!\n";
	    select OUTPUT;
	}
    }
    else {
	croak "Must have a repository or an output file" unless ($this->git_repo);
	my @cmd = ("fast-import");
	push @cmd, "--quiet" unless ($this->debug);
	push @cmd, "--export-marks=$marksfile";
	push @cmd, "--import-marks=$marksfile" if (-f $marksfile);
	($fast_import_pipe, $fast_import_ctx) = $this->git_repo->command_input_pipe(@cmd);
	select $fast_import_pipe;
    }

    print "progress ".$this->p4base."/...".($since_changelist ? " since \@$since_changelist":"")."\n";

    for my $p4change ($this->accumulate_changes($since_changelist)) {
	print "progress $p4change->{id} - ".time2str("%d %b %Y %H:%M:%S", $p4change->{time}, "GMT")." - $p4change->{user}->{User} - $p4change->{subject}\n";
	my $raw_changeinfo = p4_recv("describe", "-s", $p4change->{id});
	my $commit_text = $this->to_utf8($p4change->{desc});
	my $current_branch;
	my $new_branch;

	for (my $i = 0; exists $raw_changeinfo->{"action$i"}; $i++) {
	    my($action, $file, $type, $rev) = map { $raw_changeinfo->{$_} } ("action$i", "depotFile$i", "type$i", "rev$i" );
	    my($basetype, $typemods) = decode_p4_filetype($type);

	    my($branch, $git_path) = $this->decode_p4path($file);

	    unless ($git_path) {
		print "# $action $file#$rev (outside)\n";
		next;
	    }

	    unless ($branch) {
		print "# $action $file#$rev (not mapped)\n";
		next;
	    }

	    print "# $action $file#$rev (-> $branch)\n";

	    if (!$current_branch || $branch ne $current_branch) {
		if ($new_branch) {
		    print "reset refs/tags/".$this->remotename."/$new_branch/root\n";
		    print "from :$p4change->{id}\n";
		    print "\n";
		    undef $new_branch;
		}

		print "commit refs/remotes/".$this->remotename."/$branch\n";
		print "mark :$p4change->{id}\n";
		print "committer $p4change->{user}->{FullName} <$p4change->{user}->{Email}> $p4change->{time} +0000\n";
		print "data ".length($commit_text)."\n";
		print "$commit_text\n";
		if (!$seen_branch{$branch}) {
		    $seen_branch{$branch} = 1;
		    if ($branch_exists{$branch}) {
			print "from refs/remotes/".$this->remotename."/$branch^0\n";
		    }
		    elsif (exists $branch_grafts{$branch}) {
			unless ($branch_grafts{$branch} == 0) {
			    print "merge :$branch_grafts{$branch}\n";
			}
			$new_branch = $branch;
		    }
		    else {
			if ($action eq 'branch') {
			    my($branch_action_info) = p4_recv("filelog", "$file#$rev");
			    my $branch_from;
			    for (my $i = 0; exists $branch_action_info->{"how0,$i"}; ++$i) {
				if ($branch_action_info->{"how0,$i"} eq "branch from") {
				    $branch_from = $branch_action_info->{"file0,$i"};
				    last;
				}
			    }
			    die "P4 branch '$branch' not created by branching\n" unless ($branch_from);
			    my($source_branch, $source_path) = $this->decode_p4path($branch_from);
			    if ($source_branch) {
				# We should really try to pinpoint the exact commit this is based on... but how?
				# We'd have to scan all the branch actions in this change to see which rev on the source branch they are taking,
				# then find the earliest changelist on the source branch that does not change any files to beyond that source revision.
				print "merge refs/remotes/".$this->remotename."/$source_branch\n";
			    }
			    else {
				die "P4 branch '$branch' not based on a known branch: $branch_from\n";
			    }
			}
			else {
			    die "P4 branch '$branch' not started with a branch submission\n" unless (!@known_branches);
			}
			$branch_exists{$branch} = 1;
			$new_branch = $branch;
		    }
		}
		$current_branch = $branch;
	    }

	    if ($action eq 'delete' || $action eq 'purge') {
		print "D $git_path\n";
	    }
	    else {
		my $tmpfilename = ($ENV{TMPDIR} || "/tmp")."/p4fi".sprintf("%x%x%x", rand() * 0x10000, $$, time);
		sysopen(DATA, $tmpfilename, O_WRONLY|O_EXCL|O_CREAT, 0600) or die "Unable to write $tmpfilename: $!\n";
		my $filterpipe = ($basetype eq 'text' && $typemods =~ /k/) && IO::Pipe->new;
		my $printpid = fork;
		die "Cannot fork: $!\n" unless (defined $printpid);
		if ($printpid == 0) {
		    if ($filterpipe) {
			$filterpipe->writer;
			open(STDOUT, ">&=".$filterpipe->fileno) or die "Unable to redirect stdout: $!\n";
		    }
		    else {
			open(STDOUT, ">&=".(fileno DATA)) or die "Unable to redirect stdout: $!\n";
		    }
		    exec "p4", "print", "-q", "$file#$rev" or die "Unable to exec p4 print: $!\n";
		}
		if ($filterpipe) {
		    my $restricted = $typemods =~ /k(o?)/ && $1 eq 'o';
		    $filterpipe->reader;
		    my $changes = 0;
		    my $lines = 0;
		    while (<$filterpipe>) {
			++$lines;
			s{\$Id: \S+\#\d+ \$}{\$Id\$}g && ++$changes;
			s{\$Header: [^\$]+ \$}{\$Header\$}g && ++$changes;
			s{\$(Author|Date|DateTime|Change|File|Revision): [^\$]+ \$}{\$$1\$}g && ++$changes
			    unless ($restricted);
			print DATA;
		    }
		    $filterpipe->close;
		}
		waitpid($printpid, 0) or die "Unable to wait for $printpid: $!\n";
		my $printstatus = $?;
		$printstatus == 0 or die "p4 print exited: ".PerforceLink::decode_exitstatus($printstatus)."\n";
		close(DATA);

		my $file_size = -s $tmpfilename;
		my $mode = ($typemods =~ /x/) ? "100755" : "100644";
		print "M $mode inline $git_path\n";
		print "data $file_size\n";
		open(DATA, $tmpfilename) or die "Unable to read temporary file: $!\n";
		my $remain = $file_size;
		my $got = 0;
		my $buf;
		while (($got = sysread(DATA, $buf, 16384)) > 0) {
		    $remain -= $got;
		    print $buf;
		}
		if ($remain != 0) {
		    die "Lost $remain bytes when reading temp file\n";
		}
		unlink $tmpfilename;
		print "\n";
		$data_sent += $file_size;
	    }
	}

	if ($new_branch) {
	    print "reset refs/tags/".$this->remotename."/$new_branch/root\n";
	    print "from :$p4change->{id}\n";
	    print "\n";
	}

	if ($this->tag_changelists) {
	    print "reset refs/tags/".$this->remotename."/$p4change->{id}\n";
	    print "from :$p4change->{id}\n";
	    print "\n";
	}

	++$chgcounter;

	my %need_checkpoint;
	$need_checkpoint{time} = 1 if ($this->checkpoint_interval && time >= ($last_checkpoint->[0]+$this->checkpoint_interval));
	$need_checkpoint{commits} = 1 if ($this->checkpoint_commits && $chgcounter >= ($last_checkpoint->[1]+$this->checkpoint_commits));
	$need_checkpoint{bytes} = 1 if ($this->checkpoint_bytes && $data_sent >= ($last_checkpoint->[2]+$this->checkpoint_bytes));

	if (keys %need_checkpoint) {
	    print "checkpoint\n";
	    print "progress Checkpoint (".join(", ", sort keys %need_checkpoint).") \@$p4change->{id}\n";
	    $last_checkpoint = [time, $chgcounter, $data_sent];
	}

	$last_change = $p4change;
	last if ($this->max_changes && $chgcounter >= $this->max_changes);
    }

    print "progress All done; $chgcounter changes, $data_sent bytes\n";

    if ($fast_import_ctx) {
	$this->git_repo->command_close_pipe($fast_import_pipe, $fast_import_ctx);
    }

    return $last_change && $last_change->{id};
}

sub get_config_optional($$) {
    my $this = shift;
    $this->git_repo or croak "No repo";
    my $key = shift;

    try {
	return $this->git_repo->command_oneline("config", "--get", $key);
    } catch Git::Error::Command with {
	return undef;
    }
}

sub get_current_branch($) {
    my $this = shift;
    $this->git_repo or croak "No repo";
    try {
	my $head_ref = $this->git_repo->command_oneline("symbolic-ref", "HEAD");
	return $head_ref =~ m|^refs/heads/(.+)| && $1;
    } catch Git::Error::Command with {
	# e.g. detached head
	return undef;
    }
}

sub remote_config {
    my $this = shift;
    my $key = shift;
    croak "No repo" unless $this->git_repo;
    croak "No remote name" unless $this->remotename;
    if (@_) {
	$this->git_repo->command_noisy("config", join(".", "p4-remote", $this->remotename, $key), $_[0]);
    }
    else {
	$this->git_repo->command_oneline("config", join(".", "p4-remote", $this->remotename, $key));
    }
}

sub remote_config_bool {
    my $this = shift;
    my $key = shift;
    if (@_) {
	$this->remote_config($key, $_[0] ? "true" : "false");
    }
    else {
	$this->remote_config($key) eq 'true';
    }
}

sub get_remote_config_optional {
    my $this = shift;
    my $key = shift;
    croak "No repo" unless $this->git_repo;
    croak "No remote name" unless $this->remotename;
    try {
	$this->git_repo->command_oneline("config", join(".", "p4-remote", $this->remotename, $key));
    } catch Git::Error::Command with {
	return undef;
    }
}

sub get_remote_config_collection {
    my $this = shift;
    my $key = shift;
    croak "No repo" unless $this->git_repo;
    croak "No remote name" unless $this->remotename;
    try {
	split(/\n/, $this->git_repo->command("config", "--get-all", join(".", "p4-remote", $this->remotename, $key)));
    } catch Git::Error::Command with {
	return ();
    }
}

sub set_remote_config_collection {
    my $this = shift;
    my $key = shift;
    croak "No repo" unless $this->git_repo;
    croak "No remote name" unless $this->remotename;
    try {
	$this->git_repo->command("config", "--unset-all", join(".", "p4-remote", $this->remotename, $key));
    } catch Git::Error::Command with {
	my $e = shift;
	throw $e unless ($e->value == 5);
    };
    for (@_) {
	$this->git_repo->command_noisy("config", "--add", join(".", "p4-remote", $this->remotename, $key), $_);
    }
}

sub save_config {
    my $this = shift;
    return unless ($this->git_repo);
    $this->remote_config('base', $this->p4base);
    $this->remote_config_bool('tag-changelists', $this->tag_changelists);
    $this->remote_config_bool('fast-scan', $this->fast_scan);
    for my $envvar (qw|P4PORT P4USER P4CLIENT|) {
	$this->remote_config(lc($envvar), $ENV{$envvar}) if ($ENV{$envvar});
    }
    $this->set_remote_config_collection("fetch", map { $_->[0] eq $_->[1] ? $_->[0] : "$_->[0]:$_->[1]" } @{$this->branchspecs});
    $this->remote_config("change-charset", $this->change_charset) if ($this->change_charset);
}

sub load_config {
    my $this = shift;
    return unless ($this->git_repo);
    $this->p4base($this->remote_config('base'));
    $this->tag_changelists($this->remote_config_bool('tag-changelists'));
    $this->fast_scan($this->remote_config_bool('fast-scan'));
    for my $envvar (qw|P4PORT P4USER P4CLIENT|) {
	my $value = $this->get_remote_config_optional(lc($envvar));
	$ENV{$envvar} ||= $value if ($value);
    }
    $this->branchspecs([ map { my @a = split(/:/, $_, 2); @a == 1 ? [$a[0], $a[0]] : \@a } $this->get_remote_config_collection("fetch") ]);
    $this->change_charset($this->get_remote_config_optional("change-charset"));
}

sub to_utf8 {
    my $this = shift;
    my $text = shift;
    if ($this->change_charset) {
	return encode_utf8(decode($this->change_charset, $text));
    }
    else {
	return $text;
    }
}

1;
