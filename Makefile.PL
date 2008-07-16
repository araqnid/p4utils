use 5.006001;
use ExtUtils::MakeMaker;
use utf8;

WriteMakefile(
    NAME => "Git::P4Link",
    EXE_FILES => [qw|p4-fast-import|],
    PREREQ_PM => {
	Git => undef,
	IO::Wrap => undef,
	Carp => undef,
	Encode => undef
    }
    );
