use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
WriteMakefile(
	'NAME'         => 'DBIx::XHTML_Table',
	'VERSION_FROM' => 'XHTML_Table.pm',
	'PREREQ_PM'    => { DBI => 1.20 },
);
