# Before `make install' is performed this script should be runnable with
# `make test'. After `make install' it should work as `perl test.pl'

######################### We start with some black magic to print on failure.

# Change 1..1 below to 1..last_test_to_print .
# (It may become useful if the test is moved to ./t subdirectory.)

BEGIN { $| = 1; print "1..1\n"; }
END {print "not ok 1\n" unless $loaded;}
use DBIx::XHTML_Table;
$loaded = 1;
print "ok 1\n";

######################### End of black magic.

# Insert your test code below (better if it prints "ok 13"
# (correspondingly "not ok 13") depending on the success of chunk 13
# of the test code):

# test connect
print "Test database? [n] ";
my $answer = <>;

if ($answer =~ /y/i) {
	my @creds = 'DBI';

	foreach (qw(vendor database host user pass)) {
		print ucfirst $_, ': ';
		print '(i.e. mysql) ' if /vendor/;
		my $ans = <>;
		push @creds, $ans;
	}
	chomp @creds;

	eval {
		DBI->connect(
			join(':',@creds[0..3]),
			@creds[4,5],
			{ RaiseError => 1 }
		);
	};

	my $ok = ($@ =~ /\w/) ? "2 not ok" : "ok 2";
	print $ok, "\n";
}
