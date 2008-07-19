use 5.006001;
use ExtUtils::MakeMaker;
use utf8;

WriteMakefile(
    NAME => "PerforceLink",
    EXE_FILES => [qw|p4-fast-import unmarshal|],
    PREREQ_PM => {
	Git => undef,
	IO::Wrap => undef,
	Carp => undef,
	Encode => undef,
	Class::Accessor => undef
    }
    );
