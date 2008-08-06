use 5.006001;
use ExtUtils::MakeMaker;
use utf8;

WriteMakefile(
    NAME => "PerforceLink",
    VERSION => "1.0",
    EXE_FILES => [qw|p4-git-xfer p4-missing unmarshal ignore-expansion-hunks p4-get-patch p4-apply-patch p4-am push_change p4-graph|],
    PREREQ_PM => {
	Git => undef,
	IO::Wrap => undef,
	Carp => undef,
	Encode => undef,
	Class::Accessor => undef,
	Date::Format => undef
    } );
