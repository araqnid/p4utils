use 5.006001;
use ExtUtils::MakeMaker;
use utf8;

WriteMakefile(
    NAME => "PerforceLink",
    EXE_FILES => [qw|p4-git-xfer p4-missing unmarshal ignore-expansion-hunks p4-get-patch push_change|],
    PREREQ_PM => {
	Git => undef,
	IO::Wrap => undef,
	Carp => undef,
	Encode => undef,
	Class::Accessor => undef,
	Date::Format => undef
    }
    );
