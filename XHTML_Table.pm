package DBIx::XHTML_Table;

use strict;
use vars qw($VERSION);
$VERSION = '0.97';

use DBI;
use Carp;

# GLOBALS
use vars qw(%ESCAPES $T $N);
($T,$N)  = ("\t","\n");
%ESCAPES = (
	'&' => '&amp;',
	'<' => '&lt;',
	'>' => '&gt;',
	'"' => '&quot;',
);

#################### CONSTRUCTOR ###################################

# see POD for documentation
sub new {
	my $proto = shift;
	my $class = ref($proto) || $proto;
	my $self  = {
		null_value => '&nbsp;',
	};
	bless $self, $class;

	# last arg might be GTCH (global table config hash)
	$self->{'global'} = pop if ref $_[$#_] eq 'HASH';

	# disconnected handles aren't caught :(
	if (ref $_[0] eq 'DBI::db') {
		# use supplied db handle
		$self->{'dbh'}        = $_[0];
		$self->{'keep_alive'} = 1;
	} 
	elsif (ref $_[0] eq 'ARRAY') {
		# go ahead and accept a pre-built 2d array ref
		$self->_do_black_magic(shift);
	}
	else {
		# create my own db handle
		$self->{'dbh'} = DBI->connect(@_);
		carp "Connection failed" unless $self->{'dbh'};
	}

	#return $self->{'dbh'}->ping ? $self : undef;
	return $self;
}

#################### OBJECT METHODS ################################

sub exec_query {
	my ($self,$sql,$vars) = @_;
	my $i = 0;

	# fetch the query results
	$self->{'sth'} = $self->{'dbh'}->prepare($sql) || croak $self->{'dbh'}->errstr;
	$self->{'sth'}->execute(@$vars)              || croak $self->{'sth'}->errstr;

	# store the results
	$self->{'fields_arry'} = [ map { lc }         @{$self->{'sth'}->{'NAME'}} ];
	$self->{'fields_hash'} = { map { $_ => $i++ } @{$self->{'fields_arry'}} };
	$self->{'rows'}        = $self->{'sth'}->fetchall_arrayref;

	if (exists $self->{'pk'}) {
		$self->{'pk_index'} = delete $self->{'fields_hash'}->{$self->{'pk'}};
		splice(@{$self->{'fields_arry'}},$self->{'pk_index'},1) if defined $self->{'pk_index'};
	}
}

sub get_table { 
	carp "get_table() is deprecated. Use output() instead";
	output(@_);
}

sub output {
	my ($self,$no_titles,$no_whitespace) = @_;
	return undef unless $self->{'rows'};

	$self->{'suppress_titles'} = $no_titles;
	$N = $T = '' if $no_whitespace;

	return $self->_build_table;
}

sub modify_tag {
	my ($self,$tag,$attribs,$cols) = @_;
	$tag = lc $tag;

	# apply attributes to specified columns
	if (ref $attribs eq 'HASH') {
		$cols = [$cols = $cols || 'global'] unless ref $cols eq 'ARRAY';
		foreach my $attrib (keys %$attribs) {
			foreach (@$cols) {
				$self->{lc $_}->{$tag}->{$attrib} = $attribs->{$attrib};
			}
		}
	}
	# or handle a special case (e.g. <caption>)
	else {
		# cols is really attribs now, attribs is just a scalar
		$self->{'global'}->{$tag}            = $attribs;
		$self->{'global'}->{$tag."_attribs"} = $cols;
	}
}

sub map_cell {
	my ($self,$sub,$cols) = @_;

	$cols = $self->_refinate($cols);
	#$self->_map_it($cols,$_,$sub) foreach @{$self->{'rows'}};
	$self->{'map_cell'} = { cols => $cols, 'sub' => $sub };
}

sub map_col { 
	#FIXME: doesn't seem to be working
	carp "map_col() is deprecated. Use map_cell() instead";
	map_cell(@_);
}

sub map_head {
	my ($self,$sub,$cols) = @_;

	$cols = $self->_refinate($cols);
	#$self->_map_it($cols,$self->{'fields_arry'},$sub);
	$self->{'map_head'} = { cols => $cols, 'sub' => $sub };
}

sub add_col_tag {
	my ($self,$attribs) = @_;
	$self->{'global'}->{'colgroup'} = {} unless $self->{'colgroups'};
	push @{$self->{'colgroups'}}, $attribs;
}

sub set_group {
	my ($self,$group,$nodup,$value) = @_;
	$self->{'group'} = lc $group;
	$self->{'nodup'} = $value || $self->{'null_value'} if $nodup;

	my $index = $self->{'fields_hash'}->{$group} || 0;

	# initialize the first 'repetition'
	my $rep   = $self->{'rows'}->[0]->[$index];

	# loop through the whole rows array, storing
	# the points at which a new group starts
	for my $i (0..$self->get_row_count - 1) {
		my $new = $self->{'rows'}->[$i]->[$index];
		push @{$self->{'body_breaks'}}, $i - 1 unless ($rep eq $new);
		$rep = $new;
	}

	push @{$self->{'body_breaks'}}, $self->get_row_count - 1;
}

sub calc_totals {

	my ($self,$cols,$mask) = @_;
	return undef unless $self->{'rows'};

	$self->{'totals_mask'} = $mask;
	$cols = $self->_refinate($cols);
	my @indexes = map { $self->{'fields_hash'}->{lc $_} } @$cols;

	$self->{'totals'} = $self->_total_chunk($self->{'rows'},\@indexes);
}

sub calc_subtotals {

	my ($self,$cols,$mask,$nodups) = @_;

	return undef unless $self->{'rows'};

	$self->{'subtotals_mask'} = $mask;
	$cols = $self->_refinate($cols);
	my @indexes = map { $self->{'fields_hash'}->{lc $_} } @$cols;

	my $beg = 0;
	foreach my $end (@{$self->{'body_breaks'}}) {
		my $chunk = ([@{$self->{'rows'}}[$beg..$end]]);
		push @{$self->{'sub_totals'}}, $self->_total_chunk($chunk,\@indexes);
		$beg = $end + 1;
	}
}

sub set_pk {
	my $self = shift;
	my $pk   = shift || 'id';
	warn "too late to set primary key" if exists $self->{'rows'};
	$self->{'pk'} = lc $pk;
}

sub get_col_count {
	my ($self) = @_;
	my $count = scalar @{$self->{'fields_arry'}};
	return $count;
}

sub get_row_count {
	my ($self) = @_;
	my $count = scalar @{$self->{'rows'}};
	return $count;
}

sub get_current_row {
	return shift->{'current_row'};
}

sub get_current_col {
	return shift->{'current_col'};
}

sub set_row_colors {
	my ($self,$colors,$cols) = @_;

	$colors = [$colors] unless ref $colors eq 'ARRAY';
	$cols   = $self->_refinate($cols);

	# assign each column or global a list of colors
	# have to deep copy here, hence the temp
	foreach (@$cols) {
		my @tmp = @$colors;
		$self->{lc $_}->{'colors'} = \@tmp;
	}

}

sub set_null_value {
	my ($self,$value) = @_;
	$self->{'null_value'} = $value;
}


#################### UNDER THE HOOD ################################

sub _build_table {
	my ($self)  = @_;
	my $attribs = $self->{'global'}->{'table'};

	my $cdata   = $self->_build_head;
	$cdata     .= $self->_build_body   if $self->{'rows'};
	$cdata     .= $self->_build_foot   if $self->{'totals'};

	return _tag_it('table', $attribs, $cdata) . $N;
}

sub _build_head {
	my ($self) = @_;
	my ($attribs,$cdata,$caption);
	my $output = '';

	# build the <caption> tag if applicable
	if ($caption = $self->{'global'}->{'caption'}) {
		$attribs = $self->{'global'}->{'caption_attribs'};
		$cdata   = $self->_xml_encode($caption);
		$output .= $N.$T . _tag_it('caption', $attribs, $cdata);
	}

	# build the <colgroup> tags if applicable
	if ($attribs = $self->{'global'}->{'colgroup'}) {
		$cdata   = $self->_build_head_colgroups();
		$output .= $N.$T . _tag_it('colgroup', $attribs, $cdata);
	}

	# go ahead and stop if they don't want the titles
	return "$output\n" if $self->{'suppress_titles'};

	# prepare <tr> tag info
	my $tr_attribs = $self->{'head'}->{'tr'} || $self->{'global'}->{'tr'};
	my $tr_cdata   = $self->_build_head_row();

	# prepare the <thead> tag info
	$attribs = $self->{'head'}->{'thead'} || $self->{'global'}->{'thead'};
	$cdata   = $N.$T . _tag_it('tr', $tr_attribs, $tr_cdata) . $N.$T;

	# add the <thead> tag to the output
	$output .= $N.$T . _tag_it('thead', $attribs, $cdata) . $N;
}

sub _build_head_colgroups {
	my ($self) = @_;
	my (@cols,$output);

	return unless $self->{'colgroups'};
	return undef unless @cols = @{$self->{'colgroups'}};

	foreach (@cols) {
		$output .= $N.$T.$T . _tag_it('col', $_);
	}
	$output .= $N.$T;

	return $output;
}

sub _build_head_row {
	my ($self) = @_;
	my $output = $N;
	my @copy   = @{$self->{'fields_arry'}};

	foreach my $field (@copy) {
		my $attribs = $self->{$field}->{'th'} || $self->{'head'}->{'th'} || $self->{'global'}->{'th'};
		$field = _map_it($self->{'map_head'},$field,$field);
		$field = ucfirst $field unless $self->{'global'}->{'no_ucfirst'};
		$output .= $T.$T . _tag_it('th', $attribs, $field) . $N;
	}

	return $output . $T;
}

sub _build_body {

	my ($self)   = @_;
	my $beg      = 0;
	my $output;

	# if a group was not set via set_group(),
	# then use the entire 2-d array
	my @indicies = exists $self->{'body_breaks'}
		? @{$self->{'body_breaks'}}
		: ($self->get_row_count -1);

	# the skinny here is to grab a slice
	# of the rows, one for each group
	foreach my $end (@indicies) {
		my $body_group = $self->_build_body_group([@{$self->{'rows'}}[$beg..$end]]);
		my $attribs    = $self->{'global'}->{'tbody'} || $self->{'body'}->{'tbody'};
		my $cdata      = $N . $body_group . $T;

		$output .= $T . _tag_it('tbody',$attribs,$cdata) . $N;
		$beg = $end + 1;
	}
	return $output;
}

sub _build_body_group {

	my ($self,$chunk) = @_;
	my ($output,$cdata);
	my $attribs = $self->{'body'}->{'tr'} || $self->{'global'}->{'tr'};
	my $pk_col = '';

	# build the rows
	for my $i (0..$#$chunk) {
		my @row  = @{$chunk->[$i]};
		$pk_col  = splice(@row,$self->{'pk_index'},1) if defined $self->{'pk_index'};
		$cdata   = $self->_build_body_row(\@row, ($i and $self->{'nodup'} or 0), $pk_col);
		$output .= $T . _tag_it('tr',$attribs,$cdata) . $N;
	}

	# build the subtotal row if applicable
	if (my $subtotals = shift @{$self->{'sub_totals'}}) {
		$cdata   = $self->_build_body_subtotal($subtotals);
		$output .= $T . _tag_it('tr',$attribs,$cdata) . $N;
	}

	return $output;
}

sub _build_body_row {
	my ($self,$row,$nodup,$pk) = @_;

	my $group  = $self->{'group'};
	my $index  = $self->{'fields_hash'}->{$group} if $group;
	my $output = $N;
	my $colors;

	$self->{'current_row'} = $pk;

	for (0..$#$row) {
		my $name    = $self->{'fields_arry'}->[$_];
		my $attribs = $self->{$name}->{'td'} || $self->{'global'}->{'td'};
		my $cdata   = $row->[$_] || $self->{'null_value'};

		$self->{'current_col'} = $name;

		$cdata = _map_it($self->{'map_cell'},$cdata,$name);

		# handle 'no duplicates'
		$cdata = $self->{'nodup'} if $nodup and $index == $_;

		# rotate colors if found
		if ($colors = $self->{$name}->{'colors'}) {
			$attribs->{'bgcolor'} = _rotate($colors);
		}

		$output .= $T.$T . _tag_it('td', $attribs, $cdata) . $N;
	}
	return $output . $T;
}

sub _build_body_subtotal {
	my ($self,$row) = @_;
	my $output = $N;

	return '' unless $row;

	for (0..$#$row) {
		my $name    = $self->{'fields_arry'}->[$_];
		my $attribs = $self->{$name}->{'th'} || $self->{'body'}->{'th'} || $self->{'global'}->{'th'};
		my $sum     = ($row->[$_]);

		# use sprintf if mask was supplied
		if ($self->{'subtotals_mask'} and defined $sum) {
			$sum = sprintf($self->{'subtotals_mask'},$sum);
		}
		else {
			$sum = (defined $sum) ? $sum : $self->{'null_value'};
		}

		$output .= $T.$T . _tag_it('th', $attribs, $sum) . $N;
	}
	return $output . $T;
}

sub _build_foot {
	my ($self) = @_;

	my $tr_attribs = $self->{'global'}->{'tr'} || $self->{'foot'}->{'tr'};
	my $tr_cdata   = $self->_build_foot_row();

	my $attribs = $self->{'foot'}->{'tfoot'} || $self->{'global'}->{'tfoot'};
	my $cdata   = $N.$T . _tag_it('tr', $tr_attribs, $tr_cdata) . $N.$T;

	return $T . _tag_it('tfoot',$attribs,$cdata) . $N;
}

sub _build_foot_row {
	my ($self) = @_;

	my $output = $N;
	my $row    = $self->{'totals'};

	for (0..$#$row) {
		my $name    = $self->{'fields_arry'}->[$_];
		my $attribs = $self->{$name}->{'th'} || $self->{'foot'}->{'th'} || $self->{'global'}->{'th'};
		my $sum     = ($row->[$_]);

		# use sprintf if mask was supplied
		if ($self->{'totals_mask'} and defined $sum) {
			$sum = sprintf($self->{'totals_mask'},$sum)
		}
		else {
			$sum = defined $sum ? $sum : $self->{'null_value'};
		}

		$output .= $T.$T . _tag_it('th', $attribs, $sum) . $N;
	}
	return $output . $T;
}

# builds a tag and it's enclosed data
sub _tag_it {
	my ($name,$attribs,$cdata) = @_;
	my $text = "<\L$name\E";

	# build the attributes if any - skip blank vals
	while(my ($k,$v) = each %{$attribs}) {
		$v = _rotate($v) if (ref $v eq 'ARRAY');
		$text .= qq| \L$k\E="$v"|;
	}
	$text .= (defined $cdata) ? ">$cdata</$name>" : '/>';
}

# used by map_cell() and map_head()
sub _map_it {
	my ($hash,$datum,$col) = @_;
	return $datum unless $hash;

	my $cols = $hash->{'cols'};
	my $sub  = $hash->{'sub'};

	foreach (@$cols) {
		$datum = $sub->($datum) if $_ eq $col;
	}
	return $datum;
}

# used by calc_totals() and calc_subtotals()
sub _total_chunk {
	my ($self,$chunk,$indexes) = @_;
	my %totals;

	foreach my $row (@$chunk) {
		foreach (@$indexes) {
			$totals{$_} += $row->[$_] if $row->[$_] =~ /^[-0-9\.]+$/;
		}	
	}

	return [ map { defined $totals{$_} ? $totals{$_} : undef } sort (0..$self->get_col_count() - 1) ];
}

# uses %ESCAPES to convert the '4 Horsemen' of XML
# big thanks to Matt Sergeant 
sub _xml_encode {
    my ($self,$str) = @_;
    $str =~ s/([&<>"])/$ESCAPES{$1}/ge;
	return $str;
}

# returns value of and moves first element to last
sub _rotate {
	my $ref  = shift;
	my $next = shift @$ref;
	push @$ref, $next;
	return $next;
}

# always returns an array ref
sub _refinate {
	my ($self,$ref) = @_;
	#FIXME: following line dies if map_head called before exec_query
	@$ref = @{$self->{'fields_arry'}} unless defined $ref;
	$ref = [$ref] unless ref $ref eq 'ARRAY';
	return $ref; # make sure nothing changes $ref !!
}

# assigns a non-DBI supplied data table (2D array ref)
sub _do_black_magic {
	my ($self,$ref) = @_;
	my $i = 0;
	$self->{'fields_arry'} = [ map { lc         } @{ shift @$ref } ];
	$self->{'fields_hash'} = { map { $_ => $i++ } @{$self->{'fields_arry'}} };
	$self->{'rows'}        = $ref;
}

# disconnect database handle if i created it
sub DESTROY {
	my ($self) = @_;
	unless ($self->{'keep_alive'}) {
		$self->{'dbh'}->disconnect if defined $self->{'dbh'};
	}
}

1;
__END__

=head1 NAME

DBIx::XHTML_Table - Create XHTML tables from SQL queries

=head1 SYNOPSIS

  use DBIx::XHTML_Table;

  # database credentials - fill in the blanks
  my ($dsrc,$usr,$pass) = ();

  my $table = DBIx::XHTML_Table->new($dsrc,$usr,$pass) or die;

  $table->exec_query("
	select foo from bar
	where baz='qux'
	order by foo
  ");

  print $table->output();

  # and much more, read on . . .

=head1 DESCRIPTION

B<XHTML_Table> will execute SQL queries and return the results 
(as a scalar 'string') wrapped in XHTML tags. Methods are provided 
for determining which tags to use and what their attributes will be.
Tags such as <table>, <tr>, <th>, and <td> will be automatically
generated, you just have to specify what attributes they will use.

This module was created to fill a need for a quick and easy way to
create 'on the fly' XHTML tables from SQL queries for the purpose
of 'quick and dirty' reporting. It is not intended for serious
production use, although it use is viable for prototyping and just
plain fun.

The DBIx::XHTML_Table homepage is now available, but still under
construction. A partially complete FAQ and CookBook are available
there, as well as the Tutorial, download and support info: 

http://jeffa.perlmonk.org/XHTML_Table/


=head1 CONSTRUCTOR

=over 4

=item B<style 1>

  $obj_ref = new DBIx::XHTML_Table(@credentials[,$attribs])
  
  # note - all optional args are denoted inside brackets

Construct a new XHTML_Table object by supplying the database
credentials:

  # mysql example
  my $table = DBIx::XHTML_Table->new(
    'DBI:mysql:database:host',   # datasource
    'user',                      # user name
    'password',                  # user password
  ) or die "couldn't connect!";

The constuctor will simply pass the credentials to the DBI::connect()
method - see L<DBI> as well as the one for your corresponding DBI
driver module (DBD::Oracle, DBD::Sysbase, DBD::mysql, etc) for the
proper format for 'datasource'.

  my $table = DBIx::XHTML_Table->new(@credentials,$table_attribs);

The $table_attribs argument is optional - it should be a hash reference
whose keys are the names of any XHTML tag (colgroup and col are
very experimental right now), and the values are hash references
containing the desired attrbutes for those tags:

  # valid example for last argument
  my $table_attribs = {
    table => {
      width       => '75%',
      cellspacing => '0',
      rules       => 'groups',
    },
    caption => 'Example',
    td => {
      align => 'right',
    },
  };

The purpose of $table_attribs is to allow the bypassing of having to
call modify_tag() (see below) multiple times. Right now, $attribs
can only modify 'global' tags - i.e., you can't specify attributes
by Areas (head, body, or foot) or Columns (specific to the query
result) - see modify_tag() below for more on Areas and Columns.

A particularly useful 'attrib' is no_ucfirst:
  my $table_attribs = {
    no_ucfirst => 1,
  };

This allows you to bypass the automatic upper casing of the first
word in each of the column names in the table header.

=item B<style 2>

  $obj_ref = new DBIx::XHTML_Table($DBH[,$attribs])

The first style will result in the database handle being created
and destroyed 'behind the scenes'. If you need to keep the database
connection open after the XHTML_Table object is destroyed, then
create one yourself and pass it to the constructor:

  my $DBH   = DBI->connect($dsource,$usr,$passwd) || die;
  my $table = DBIx::XHTML_Table->new($DBH);
    # do stuff
  $DBH->disconnect;

=item B<style 3>

  $obj_ref = new DBIx::XHTML_Table($array_ref[,$attribs)

The final style allows you to bypass a database altogether if need
be. Simply pass a similar structure as the one passed back from
B<DBI>'s C<selectall_arrayref()>, that is, a list of lists:

  my $ref = [
  	[ qw(Head1 Head2 Head3) ],
	[ qw(foo bar baz)       ],
	[ qw(one two three)     ],
	[ qw(un deux trois)     ]
  ];

  my $table = DBIx::XHTML_Table->new($ref);

The only catch is that the first row will be treated as the table
heading - be sure and supply one, even you don't need it. As a side
effect, that first row will be removed from $ref upon instantiation.
You can always bypass the printing of the heading via C<output()>.

Note that I only added this feature because it was too easy and simple
not to. The intention of this module is that it be used with DBI, but
who says you have to follow the rules.

=back

=head1 OBJECT METHODS

=over 4

=item B<exec_query>

  $table->exec_query($sql[,$bind_vars])

Pass the query off to the database with hopes that data will be 
returned. The first argument is scalar that contains the SQL
code, the optional second argument can either be a scalar for one
bind variable or an array reference for multiple bind vars:

  $table->exec_query("
      SELECT BAR,BAZ FROM FOO
	  WHERE BAR = ?
	  AND   BAZ = ?
  ",[$foo,$bar])    || die 'query failed';

Consult L<DBI> for more details on bind vars.

After the query successfully exectutes, the results will be
stored interally as a 2-D array. The XHTML table tags will
not be generated until output() is invoked, and the results
can be modified via modify_tag().

=item B<output>

  $scalar = $table->output([$sans_title,$sans_whitespace])

Renders and returns the XHTML table. The first argument is a
non-zero, defined value that suppresses the column titles. The
column foots can be suppressed by not calculating totals, and
the body can be suppressed by an appropriate SQL query. The
caption and colgroup cols can be suppressed by not modifying
them. The column titles are the only section that has to be
specifically 'told' not to generate, and this is where you do that.

  print $table->output();       # produces titles by default
  print $table->output(1);      # does not produce titles

The second argument is another non-zero, defined value that will
result in the output having no text aligning whitespace, that is
no newline(\n) and tab(\t) charatcters.

=item B<get_table>

  $scalar = $table->output([$sans_title,$sans_whitespace])

Deprecated - use output() instead.

=item B<modify_tag>

  $table->modify_tag($tag,$attribs[,$cols])

This method will store a 'memo' of what attributes you have assigned
to various tags within the table. When the table is rendered, these
memos will be used to create attributes. The first argument is the
name of the tag you wish to modify the attributes of. You can supply
any tag name you want without fear of halting the program, but the
only tag names that are handled are <table> <caption> <thead> <tfoot>
<tbody> <colgroup <col> <tr> <th> and <td>. The tag name will be
converted to lowercase, so you can practice safe case insensitivity.

The next argument is a reference to a hash that contains the
attributes you wish to apply to the tag. For example, this
sets the attributes for the <table> tag:

  $table->modify_tag('table',{
      border => 2,
      width  => '100%',
      foo    => 'bar',
  });

  # a more Perl-ish way
  $table->modify_tag(table => {
      border => 2,
      width  => '100%',
      foo    => 'bar',
  });

Each KEY in the hash will be lower-cased, and each value will be 
surrounded in quotes. The foo=>bar entry illustrates that typos
in attribute names will not be caught by this module. Any
valid XHTML attribute can be used. Yes. Even JavaScript.

You can even use an array reference as the key values:

  $table->modify_tag(td => {
      bgcolor => [qw(red purple blue green yellow orange)],
  }),

Each <td> tag will get a color from the list, one at
time. When the last index is reached (orange), the next
<td> tag will get the first index (red), continuing just
like a circular queue until no more <td> tags are left.

This feature changes attributes in a horizontal fasion,
each new element is popped from the array every time a
<td> tag is created for output. Use set_row_color()
when you need to change colors in a vertical fashion.
Unfortunately, no method exists to allow other attributes
besides BGCOLOR to permutate in a vertical fashion.

The last argument is optional and can either be a scalar
representing a single column or area, or an array reference
containing multilple columns or areas. The columns will be
the corresponding names of the columns from the SQL query.
The areas are one of three values: HEAD, BODY, or FOOT.
The columns and areas you specify are case insensitive.

  # just modify the titles
  $table->modify_tag(th => {
      bgcolor => '#bacaba',
  }, 'head');

You cannot currently mix areas and columns.

If the last argument is not supplied, then the attributes will
be applied to the entire table via a global memo. However,
entries in the global memo are only used if no memos for that
column or area have been set:

  # all <td> tags will be set
  $table->modify_tag(td => {
      class => 'foo',
  });

  # only <td> tags in column BAR will be set
  $table->modify_tag(td => {
      class => 'bar',
  }, 'bar');

The order of the execution of the previous two methods calls is
commutative - it doesn't matter.

A final caveat is setting the <caption> tag. This one breaks
the signature convention:

  $table->modify_tag(tag => $value, $attrib);

Since there is only one <caption> allowed in an XHTML table,
there is no reason to bind it to a column or an area:

  # with attributes
  $table->modify_tag(caption => 'A Table Of Contents',{
      class => 'body',
  });

  # without attributes
  $table->modify_tag(caption => 'A Table Of Contents');

The only tag that cannot be modified by modify_tag() is the <col>
tag. Use add_col_tag to add these tags instead.

=item B<add_col_tag>

  $table->add_col_tag($cols)

Add a new <col> tag and attributes. The only argument is reference
to a hash that contains the attributes for this <col> tag. Multiple
<col> tags require multiple calls to this method. The <colgroup> tag
pair will be automatically generated if at least one <col> tag is
added.

Advice: use <col> and <colgroup> tags wisely, don't do this:

  # bad
  for (0..39) {
    $table->add_col_tag({
        foo => 'bar',
    });
  }

When this will suffice:

  # good
  $table->modify_tag(colgroup => {
      span => 40,
      foo  => 'bar',
  });

You should also consider using <col> tags to set the attributes
of <td> and <th> instead of the <td> and <th> tags themselves,
especially if it is for the entire table. Notice the use of the
get_col_count() method in this example:

  $table->add_col_tag({
      span  => $table->get_col_count(),
	  class => 'body',
  });

=item B<map_cell>

  $table->map_cell($subroutine[,$cols])

Map a supplied subroutine to all the <td> tag's cdata for
the specified columns.  The first argument is a reference to a
subroutine. This subroutine should shift off a single scalar at
the beginning, munge it in some fasion, and then return it.
The second argument is the column (scalar) or columns (reference
to a list of scalars) to apply this subroutine to. Example: 

  # uppercase the data in column DEPARTMENT
  $table->map_cell( sub { return uc shift }, 'department');

One temptation that needs to be addressed is using this method to
color the cdata inside a <td> tag pair. For example:

  # don't be tempted to do this
  $table->map_cell(sub {
    return qq|<font color="red">| . shift . qq|</font>|;
  }, 'first_name');

  # when this will work (and you dig CSS)
  $table->modify_tag(td => {
	  style => 'Color: red;',
  }, 'first_name');

Another good candidate for this method is turning the cdata
into an anchor:

  $table->map_cell(sub {
    my $raw = shift;
    return qq|<a href="/foo.cgi?process=$raw">$raw</font>|;
  }, 'category');
  
If [$cols] is not specified, all columns are assumed. This
method does not permantly change the data. 

=item B<map_col>

  $table->map_col($subroutine[,$cols])

Deprecated - use map_cell() instead.

=item B<map_head>

  $table->map_head($subroutine[,$cols])

Just like map_cell(), except it modifies only column headers, 
i.e. the <th> data located inside the <thead> section. The
immediate application is to ucfirst() the column headers:

  $table->map_head(sub { ucfirst shift });

If [$cols] is not specified, all columns are assumed. This
method does not permantly change the data. 

=item B<set_row_colors>

  $table->set_row_colors($colors[,$cols])

Assign a list of colors to the body cells for specified columns
or the entire table if none specified for the purpose of
alternating colored rows.  This is not handled in the same
way that modify_tag() rotates the BGCOLOR attribute.
That method rotates on each column (think horizontally),
this one rotates on each row (think vertically). However:

  # this:
  $table->modify_tag(td => {
	  bgcolor => [qw(green green red red)],
  }, [qw(first_name last_name)]);

  # produces the same output as:
  $table->set_row_colors(
      [qw(green red)],
	  [qw(first_name last_name)],
  );

Again, $cols is optional, and can be either a single column
(scalar) or multiple columns (reference to a list of scalars),
and if not present, all columns are assumed.

Another way to alternate row colors is by using the set_group()
method (explained further below) and modify_tag() on <tbody>:

  $table->set_group('<pick the most redundant column here!>');

  $table->modify_tag(tbody => {
	  bgcolor => [qw(green red)],
  });

=item B<set_null_value>

  $table->set_null_value($new_null_value)

Change the default null_value (&nbsp;) to something else.  
Any column that is undefined will have this value 
substituted instead.

=item B<set_pk>

  $table->set_pk('name of primary key column');

This method must be called before exec_query() in order to work!

This is highly specialized method - the need is when you want to select
the primary key along with the columns you want to display, but you
don't want to display it as well. The value will be accessible via
get_current_row(). This is useful as a a callback via map_cell(). 
Consider the following:

  $table->map_cell(sub { 
    my $datum = shift;
    my $row   = $table->get_current_row();
    my $col   = $table->get_current_col();
    return qq|<input type="text" name="$row:$col" value="$datum">|;
  });

This will render a "poor man's" spreadsheet, provided that set_pk() was
called with the proper primary key before exec_query() was called.
Now each input has a name that can be split to reveal which row and
column the value belongs to.

Big thanks to Jim Cromie for the idea.

=item B<set_group>

  $table->set_group($column[,$no_dups,$replace_with])

Assign one column as the main column. Every time a new row is
encountered for this column, a <tbody> tag is written. An optional
second argument that contains a defined, non-zero value will cause duplicates
to be permanantly eliminated for this row. An optional third argument
specifies what value to replace for duplicates, default is &nbsp;

  # replace duplicates with the global 'null_value'
  $table->set_group('Branch',1);

  # replace duplicates with a new value
  $table->set_group('Branch',1,'----');
  
  # or in a more Perl-ish way
  $table->set_group('Branch',nodups=>'----');

Don't assign a column that has a different value each row, choose
one that is a super class to the rest of the data, for example,
pick album over song, since an album consists of songs. See the Tutorial
below (you know, past the chickens) for more on this method.

So, what's it good for? If you supply the following two attributes
(and their associated values) to the <table> tag:

  # only usefull if you set a group, by the way
  $table->modify_tag(table => {
	  cellspacing => '0',
	  rules       => 'groups',
  });

then horizontal lines will only appear at the point where the 'grouped' 
column changes.  This had to be implemented in the past with <table>'s
inside of <table>'s. Much nicer! Add this for a nice coloring trick:

  # works with or without setting a group
  $table->modify_tag(tbody => {
	  bgcolor => [qw(insert rotating colors here)],
  });

=item B<calc_totals>

  $table->calc_totals([$cols,$mask])

Computes totals for specified columns. The first argument is the column
or columns to sum, again a scalar or array reference is the requirement.
If $cols is not specified, all columns will be totaled. Non-numbers will
be ignored, negatives and floating points are supported, but you have to
supply an appropriate sprintf mask, which is the optional second argument,
in order for the sum to be correctly formatted. See L<sprintf> for further
details.  

=item B<calc_subtotals>

  $table->calc_subtotals([$cols,$mask])

Computes subtotals for specified columns. It is manditory that you
first specify a group via set_group() before you call this method.
Each subtotal is tallied from the rows that have the same value
in the column that you specified to be the group. At this point, only
one subtotal row per group can be calculated and displayed. 

=item B<get_col_count>

  $scalar = $table->get_col_count()

Returns the number of columns in the table.

=item B<get_row_count>

  $scalar = $table->get_row_count()

Returns the numbers of body rows in the table.

=item B<get_current_row>

  $scalar = $table->get_current_row()

Returns the value of the primary key for the current row being processed.
This method is only meaningful inside a map_cell() callback; if you access
it otherwise, you will either receive undef or the value of the primary
key of the last row of data.

=item B<get_current_col>

  $scalar = $table->get_current_col()

Returns the name of the column being processed.
This method is only meaningful inside a map_cell() callback; if you access
it otherwise, you will either receive undef or the the name of the last
column specified in your SQL statement.

=back

=head1 TAG REFERENCE

    TAG        CREATION    BELONGS TO AREA
+------------+----------+--------------------+
| <table>    |   auto   |       ----         |
| <caption>  |  manual  |       ----         |
| <colgroup> |  manual  |       ----         |
| <col>*     |  manual  |       ----         |
| <thead>    |   auto   |       head         |
| <tbody>    |   auto   |       body         |
| <tfoot>    |   auto   |       foot         |
| <tr>       |   auto   |  head,body,foot    |
| <td>       |   auto   |       body         |
| <th>       |   auto   |  head,body,foot    |
+------------+-------------------------------+

 * All tags use modify_tag() to set attributes
   except <col>, which uses add_col_tag() instead

=head1 BUGS

If you have found a bug, please visit Best Practical
Solution's CPAN bug tracker at http://rt.cpan.org.

=over 4

=item Problems with 'SELECT *'

Users are recommended to avoid 'select *' and instead
specify the names of the columns. Problems have been reported
using 'select *' with SQLServer7 will cause certain 'text' type 
columns not to display. I have not experienced this problem
personally, and tests on Oracle and mySQL show that they are not
affected by this. SQLServer7 users, please help me confirm this. :)

=item Not specifying <body> tag in CGI scripts

I anticipate this module to be used by CGI scripts, and when
writing my own 'throw-away' scripts, I noticed that Netscape 4
will not display a table that contains XHTML tags IF a <body>
tag is NOT found. Be sure and print one out.

=item map_head() called before exec_query()

Whoops. Don't do that. Will be fixed in next version.

=item set_row_colors() does not use XHTML

I just know caught this. Big whoops. I'll be working
to fix this for the next version as well.

=back

=head1 CREDITS

Briac 'OeufMayo' PilprE<eacute> for the name

Mark 'extremely' Mills for patches and suggestions

Jim Cromie for presenting the whole spreadsheet idea.

Matt Sergeant for DBIx::XML_RDB

Perl Monks for the education

=head1 SEE ALSO 

L<DBI>

=head1 AUTHOR 

Jeffrey Hayes Anderson <captvanhalen@yahoo.com>

=head1 COPYRIGHT

Copyright (c) 2001 Jeffrey Hayes Anderson. All rights reserved.
DBIx::XHTML_Table is free software; it may be copied, modified,
and/or redistributed under the same terms as Perl itself.

=cut
