package DBIx::XHTML_Table;

use strict;
use vars qw($VERSION);
$VERSION = '0.82';

use DBI;
use Data::Dumper;
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
	my $self = {
		null_value => '&nbsp;',
	};
	bless $self, $class;

	# disconnected handles aren't caught :(
	if (ref $_[0] eq 'DBI::db') {
		# use supplied db handle
		$self->{dbh}        = $_[0];
		$self->{keep_alive} = 1;
	}
	else {
		# create my own db handle
		$self->{dbh} = DBI->connect(@_);
		carp "Connection failed" unless $self->{dbh};
	}

	return $self->{dbh}->ping ? $self : undef;
}

#################### OBJECT METHODS ################################

sub exec_query {
	my ($self,$sql,$vars) = @_;
	my $i = 0;

	$self->{sth} = $self->{dbh}->prepare($sql) || croak $self->{dbh}->errstr;
	$self->{sth}->execute(@$vars)              || croak $self->{sth}->errstr;

	$self->{fields_arry} = [ map { lc }         @{$self->{sth}->{NAME}} ];
	$self->{fields_hash} = { map { $_ => $i++ } @{$self->{fields_arry}} };
	$self->{rows}        = $self->{sth}->fetchall_arrayref;
}

sub get_table {
	my ($self,$no_titles,$no_whitespace) = @_;
	return undef unless $self->{rows};

	$self->{suppress_titles} = $no_titles;
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
	# or handle a special case (e.g. <CAPTION>)
	# feature: <TABLE> could be safely modified in this manner
	else {
		# cols is really attribs now, attribs is just a scalar
		$self->{global}->{$tag."_value"} = $attribs;
		$self->{global}->{$tag}          = $cols;
	}
}

sub map_col {
	my ($self,$sub,$cols) = @_;

	$cols = [$cols] unless ref $cols eq 'ARRAY';

	# apply user's subroutine to specified columns
	foreach my $row(@{$self->{rows}}) {
		foreach my $col (@$cols) {
			$col = lc $col;
			my $index = $self->{fields_hash}->{$col};
			$row->[$index] = $sub->($row->[$index]);
		}
	}
}

sub add_colgroup {
	my ($self,$attribs) = @_;
	$self->{global}->{colgroup} = {} unless $self->{colgroups};
	push @{$self->{colgroups}}, $attribs;
}

# needs refactoring
sub calc_subtotals {
	my ($self,$cols,$mask,$nodups) = @_;
	my $group = $self->{group} || return undef;
	$group    = $self->{fields_hash}->{$group};
	my ($last,%totals,@indexes,$col_count) = '';

	return undef unless $self->{rows};

	$self->{subtotals_mask} = $mask;

	$cols    = [$cols] unless ref $cols eq 'ARRAY';
	@indexes = map { $self->{fields_hash}->{lc $_} } @$cols;

	my $first = 1;
	my $count = 0;
	foreach my $row (@{$self->{rows}}) {

		my $tmp = $row->[$group];

		unless ($last eq $tmp or $first) {
			# new group
			push ( @{$self->{sub_totals}}, 
				($count <= 1 and defined $nodups)
				? []
				: [ map { defined $totals{$_} ? $totals{$_} : undef } sort (0..$#{$self->{fields_arry}}) ],
			);
			# start over
			%totals = ();
			$count = 0;
		}

		# current group or first row
		foreach my $index (@indexes) {
			$totals{$index} += $row->[$index] if $row->[$index] =~ /^[-0-9\.]+$/;
		}

		$first = 0;
		$last = $tmp;
		$count++;
	}
	# last group
	push ( @{$self->{sub_totals}}, 
		($count <= 1 and defined $nodups)
		? []
		: [ map { defined $totals{$_} ? $totals{$_} : undef } sort (0..$#{$self->{fields_arry}}) ],
	);
}

# needs refactoring
sub calc_totals {
	my ($self,$cols,$mask) = @_;
	my %totals;

	return undef unless $self->{rows};

	$self->{totals_mask} = $mask;
	$cols = [$cols] unless ref $cols eq 'ARRAY';

	# calculate the totals for requested columns
	foreach my $col (@$cols) {
		$col = lc $col;
		my $index = $self->{fields_hash}->{$col};
		foreach my $row(@{$self->{rows}}) {
			$totals{$col} += $row->[$index] if $row->[$index] =~ /^[-0-9\.]+$/;
		}
	}

	# store totals in the right order, used when footer is created
	$self->{totals} = [ 
		map   { defined $totals{$_} ? $totals{$_} : undef }
		sort  { $self->{fields_hash}->{$a} <=> $self->{fields_hash}->{$b} }
		keys %{ $self->{fields_hash} }
	];
}

sub get_col_count {
	my ($self) = @_;
	my $count = scalar @{$self->{fields_arry}};
	return $count;
}

sub get_row_count {
	my ($self) = @_;
	my $count = scalar @{$self->{rows}};
	return $count;
}

sub set_row_colors {
	my ($self,$colors,$cols) = @_;

	$cols   = $self->{fields_arry} unless $cols;
	$cols   = [$cols]   unless ref $cols eq 'ARRAY';
	$colors = [$colors] unless ref $colors eq 'ARRAY';

	# assign each column or global a list of colors
	# have to deep copy here, hence the temp
	foreach (@$cols) {
		my @tmp = @$colors;
		$self->{lc $_}->{colors} = \@tmp;
	}

}

sub set_group {
	my ($self,$group,$nodup,$value) = @_;
	$self->{group} = lc $group;
	$self->{nodup} = $value || $self->{null_value} if $nodup;
}

sub set_null_value {
	my ($self,$value) = @_;
	$self->{null_value} = $value;
}


#################### UNDER THE HOOD ################################

sub _build_table {
	my ($self) = @_;
	my $table  = $self->_build_header 
	          .  $self->_build_body;
	$table    .= $self->_build_footer if $self->{totals};

	return _tag_it( 
				'TABLE', 					# the tag name
				$self->{global}->{table}, 	# any attributes
				$table,						# the cdata
			) . $N;
}

sub _build_header {
	my ($self) = @_;
	my $header;

	# build the caption if applicable
	if(my $caption = $self->{global}->{caption_value}) {
		$header .= $N.$T
				. _tag_it(
						'CAPTION',
						$self->{global}->{caption},
						$self->_xml_encode($caption)
					);
	}

	# build the colgroups if applicable
	if(my $attribs = $self->{global}->{colgroup}) {
		$header .= $N.$T
				. _tag_it(
						'COLGROUP', 
						$attribs, 
						$self->_build_header_colgroups()
					);
	}
	$header .= $N;

	# go ahead and stop if they don't want the titles
	return $header if $self->{suppress_titles};

	# build the THEAD and TH rows
	$header .= $T 
			. _tag_it(
				'THEAD',
				$self->{global}->{thead},
				$N.$T . _tag_it(
							'TR', 
							$self->{header}->{tr}, 
							$self->_build_header_row()
						) . $N.$T
			  ) 
			. $N;
}

sub _build_header_colgroups {
	my ($self) = @_;
	my (@cols,$output);

	return undef unless @cols = @{$self->{colgroups}};

	foreach (@cols) {
		$output .= $N.$T.$T . _tag_it('COL', $_);
	}
	$output .= $N.$T;

	return $output;
}

sub _build_header_row {
	my ($self) = @_;
	my $output = $N;

	foreach (@{$self->{fields_arry}}) {
		my $attribs = $self->{$_}->{th} || $self->{header}->{th} || $self->{global}->{th};
		$output .= $T.$T 
				. _tag_it('TH', $attribs, ucfirst $_) 
				. $N;
	}

	return $output . $T;
}

# needs refactoring
sub _build_body {

	my ($self) = @_;

	my $group = $self->{group};
	my $index = $self->{fields_hash}->{$group} if $group;
	my $last  = '';

	my $tbody = $T . _tag_it('TBODY',$self->{global}->{tbody}) . $N;

	my $body_out = $tbody unless $group;

	my $first = 1;
	foreach my $row (@{$self->{rows}}) {

		# build row accordng to the group
		if ($group) {
			my $tmp  = $row->[$index];
			if ($last ne $tmp) {
				unless ($first) {
					my $subtotals = shift @{$self->{sub_totals}} || '';
					$body_out .= $T 
						. _tag_it(
						  	'TR', 
							$self->{body}->{tr}, 
							$self->_build_body_subtotal($subtotals)
						) 
						. $N if $subtotals;
				}
				$body_out .= $tbody;
			}
			elsif ($self->{nodup}) {
				$row->[$index] = $self->{nodup};
			}
			$last = $tmp;
		}

		# build the row with no special attention to group
		$body_out .= $T 
				. _tag_it(
					'TR',
					$self->{body}->{tr},
					$self->_build_body_rows($row)
				  ) 
				. $N;
		$first = 0;
	}

	# build the last subtotal row if applicable - hack
	my $subtotals = shift @{$self->{sub_totals}} || '';
	$body_out .= $T 
			. _tag_it(
				'TR',
				$self->{body}->{tr}, 
				$self->_build_body_subtotal($subtotals)
			  ) 
			. $N if $subtotals;

	return $body_out;
}

sub _build_body_rows {
	my ($self,$row) = @_;
	my $output = $N;

	for (0..$#$row) {
		my $name    = $self->{fields_arry}->[$_];
		my $attribs = $self->{$name}->{td} || $self->{global}->{td};

		# rotate colors if found
		if (my $colors = $self->{$name}->{colors}) {
			$attribs->{bgcolor} = _rotate($colors);
		}

		$output .= $T.$T 
				. _tag_it('TD', $attribs, $row->[$_] || $self->{null_value}) 
				. $N;
	}
	return $output . $T;
}

sub _build_body_subtotal {
	my ($self,$row) = @_;
	my $output = $N;

	return '' unless $row;

	for (0..$#$row) {
		my $name    = $self->{fields_arry}->[$_];
		my $attribs = $self->{$name}->{th} || $self->{body}->{th} || $self->{global}->{th};
		my $sum     = ($row->[$_]);

		# use sprintf if mask was supplied
		if ($self->{subtotals_mask} and defined $sum) {
			$sum = sprintf($self->{subtotals_mask},$sum)
		}
		else {
			$sum = (defined $sum) ? $sum : $self->{null_value};
		}

		$output .= $T.$T 
				. _tag_it('TH', $attribs, $sum) 
				. $N;
	}
	return $output . $T;
}


sub _build_footer {
	my ($self) = @_;

	return $T 
			. _tag_it(
				'TFOOT',
				$self->{global}->{tfoot},
				$N.$T . _tag_it(
							'TR', 
							$self->{footer}->{tr}, 
							$self->_build_footer_row()
						) . $N.$T
			  ) 
			. $N;
}

sub _build_footer_row {
	my ($self) = @_;

	my $output = $N;
	my $row    = $self->{totals};

	for (0..$#$row) {
		my $name    = $self->{fields_arry}->[$_];
		my $attribs = $self->{$name}->{th} || $self->{footer}->{th} || $self->{global}->{th};
		my $sum     = ($row->[$_]);

		# use sprintf if mask was supplied
		if ($self->{totals_mask} and defined $sum) {
			$sum = sprintf($self->{totals_mask},$sum)
		}
		else {
			$sum = defined $sum ? $sum : $self->{null_value};
		}

		$output .= $T.$T 
				. _tag_it('TH', $attribs, $sum) 
				. $N;
	}
	return $output . $T;
}

# returns value of and moves first element to last
sub _rotate {
	my $ref  = shift;
	my $next = shift @$ref;
	push @$ref, $next;
	return $next;
}

# builds a tag and it's enclosed data
sub _tag_it {
	my ($name,$attribs,$cdata) = @_;
	my $text = "<$name";

	# build the attributes if any
	while(my ($k,$v) = each %{$attribs}) {
		if (ref $v eq 'ARRAY') {
			$v = _rotate($v);
		}
		$text .= ' ' . uc($k) . '="' . $v . '"'
	}
	$text .= (defined $cdata) ? ">$cdata</$name>" : '/>';
}

# uses %ESCAPES to convert the '4 Horsemen' of XML
# big thanks to Matt Sergeant 
sub _xml_encode {
    my ($self,$str) = @_;
    $str =~ s/([&<>"])/$ESCAPES{$1}/ge;
	return $str;
}

# disconnect database handle if i created it
sub DESTROY {
	my ($self) = @_;
	$self->{dbh}->disconnect unless $self->{keep_alive};
}

1;
__END__

=head1 NAME

DBIx::XHTML_Table - Create XHTML tables from SQL queries

=head1 SYNOPSIS

  use DBIx::XHTML_Table;

  # database credentials - fill in the blanks
  my ($dsource,$user,$pass) = ();

  # create the object
  my $table = new DBIx::XHTML_Table($dsource, $user, $pass) 
  			|| die "could not connect to database\n";

  # grab some data
  $table->exec_query("
	SELECT ARTIST,ALBUM,TITLE,YEAR,GENRE 
	FROM MP3.SONGS
	WHERE YEAR=? AND GENRE=? 
	ORDER BY ARTIST,YEAR,TITLE
  ",[$year,$genre]);    # bind vars for demonstration only

  # start tweaking the table
  $table->modify_tag('TABLE',{
	  border      => 1,
	  cellspacing => 0,
  });

  # modify all <TH> tags
  $table->modify_tag('TH',{
	  bgcolor => 'black',
	  style   => 'Color: white;',
  });

  # modify only <TD> tags for TITLE column
  $table->modify_tag('TD',{
	  align   => 'right',     # although align is deprecated
	  bgcolor => '#ABACAB',
  }, 'title');

  # values that are array refs will be rotated horizontally
  $table->modify_tag('TD',{
	  width   => 200,
	  align   => [qw(left right)],
	  bgcolor => [qw(blue red)],
  }, [qw(album year)]);

  # this rotates colors vertically down the columns
  $table->set_row_colors(
	["#D0D0D0", "#B0B0B0")],
	[qw(artist genre)],
  );

  # set the most general column as the group
  $table->set_group('artist');  # can also suppress duplicates

  # sum up the years column
  $table->calc_totals('year');

  # and if you have set a group . . .
  $table->calc_subtotals('year');

  # print out the complete table
  print $table->get_table;

=head1 DESCRIPTION

B<XHTML_Table> will execute SQL queries and return the results
wrapped in XHTML tags. Methods are provided for determining 
which tags to use and what their attributes will be. Tags
such as <TABLE>, <TR>, <TH>, and <TD> will be automatically
generated, you just have to specify what attributes they
will use.

This module was created to fill a need for a quick and easy way to
create 'on the fly' XHTML tables from SQL queries for the purpose
of 'quick and dirty' reporting. If you find yourself needing more
power over the display of your report, you should look into
templating methods such as B<HTML::Template> or B<Template-Toolkit>.
Another viable substitution for this module is to use B<DBIx::XML_RDB>
and XSL stylesheets. However, some browsers are still not XML compliant,
and XHTML_Table has the advantage of displaying at least something
on browsers that are not XML or XHTML compliant. At the worst, only
the XHTML tags will be ignored, and not the content of the report.

The user is highly recommended to become familiar with the rules and
structure of the new XHTML tags used for tables.  A good, terse
reference can be found at
http://www.w3.org/TR/REC-html40/struct/tables.html

Additionally, a simple B<TUTORIAL> is included in this documentation
toward the end, just before the third door, down the hall, past
the chickens and through a small gutter (just keep scrolling down).

=head1 CONSTRUCTOR

=over 4

=item B<style 1>

  $obj_ref = new DBIx::XHTML_Table($dsource,$usr,$passwd)

Construct a new XHTML_Table object by supplying the database
credentials: datasource, user, password: 

  my $table = new DBIx::XHTML_Table($dsource,$usr,$passwd) || die;

The constuctor will simply pass the arguments to the connect()
method from F<DBI.pm> - see L<DBI> as well as the one for your
corresponding DBI driver module - DBD::Oracle, DBD::Sysbase, 
DBD::mysql, etc. The explanation of $dsource lies therein.

=item B<style 2>

  $obj_ref = new DBIx::XHTML_Table($DBH)

The previous signature will result in the database handle
being created and destroyed 'behind the scenes'. If you need
to keep the database connection open, create one yourself
and pass it to the constructor:

  my $DBH   = DBI->connect($dsource,$usr,$passwd) || die;
  my $table = new DBIx::XHTML_Table($DBH);
    # do stuff
  $DBH->disconnect;

=back

=head1 OBJECT METHODS

=over 4

=item B<exec_query>

  $table->exec_query($sql,[$bind_vars])

Pass the query off to the database with hopes of data being 
returned. The first argument is scalar that contains the SQL
code, the second argument can either be a scalar for one
bind variable or an array reference for multiple bind vars:

  $table->exec_query("
      SELECT BAR,BAZ FROM FOO
	  WHERE BAR = ?
	  AND   BAZ = ?
  ",[$foo,$bar])    || die 'query failed';

Consult L<DBI> for more details on bind vars.

After the query successfully exectutes, the results will be
stored interally as a 2-D array. The XHTML table tags will
not be generated until B<get_table()> is invoked, and the results
can be modified via B<map_column()>.

=item B<get_table>

  $scalar = $table->get_table($sans_title,$sans_whitespace)

Renders and returns the XHTML table. The first argument is a
non-zero, defined value that suppresses the column titles. The
column footers can be suppressed by not calculating totals, and
the body can be suppressed by an appropriate SQL query. The
caption and colgroup cols can be suppressed by not modifying
them. The column titles are the only part that has to be
specifically told not to generate, and this is where you do that.

  print $table->get_table;      # produces titles by default
  print $table->get_table(1);   # does not produce titles

The second argument is another non-zero, defined value that will
result in the output having no text aligning whitespace, that is
no newline(\n) and tab(\t) charatcters.

=item B<modify_tag>

  $table->modify_tag($tag,$args,[$cols])

This method will store a 'memo' of what attributes you have assigned
to various tags within the table. When the table is rendered, these
memos will be used to create attributes. The first argument is the
name of the tag you wish to modify the attributes of. You can supply
any tag name you want without fear of halting the program, but the
only tag names that are handled are <TABLE> <CAPTION> <THEAD> <TFOOT>
<TBODY> <COLGROUP> <COL> <TR> <TH> and <TD>. The tag name will be
converted to uppercase, so you can practice safe case insensitivity.

The next argument is a reference to a hash that contains the
attributes you wish to apply to the tag. For example, this
sets the attributes for the <TABLE> tag:

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

Each KEY in the hash will be upper-cased, and each value will be 
surrounded in quotes. The foo=>bar entry illustrates that typos
in attribute names will not be caught by this module. Any
valid XHTML attribute can be used. Yes. Even JavaScript.

You can even use an array reference as the key values:

  $table->modify_tag('td',{
      bgcolor => [qw(red purple blue green yellow orange)],
  }),

Each <TD> tag will get a color from the list, one at
time. When the last index is reached (orange), the next
<TD> tag will get the first index (red), continuing just
like a circular queue until no more <TD> tags are left.

This feature changes attributes in a horizontal fasion,
each new element is popped from the array every time a
<TD> tag is created for output. Use B<set_row_color()>
when you need to change colors in a vertical fashion.
Unfortunately, no method exists to allow other attributes
besides BGCOLOR to permutate in a vertical fashion.

The last argument is optional and can either be a scalar
representing a single column or area, or an array reference
containing multilple columns or areas. The columns will be
the corresponding names of the columns from the SQL query.
The areas are one of three values: HEADER, BODY, or FOOTER.
The columns and areas you specify are case insensitive.

  # just modify the titles
  $table->modify_tag('TH',{
      bgcolor => '#bacaba',
  }, 'header');

You cannot currently mix areas and columns. 

If the last argument is not supplied, then the attributes will
be applied to the entire table via a global memo. However,
entries in the global memo are only used if no memos for that
column or area have been set:

  # all <TD> tags will be set
  $table->modify_tag('TD',{
      class => 'foo',
  });

  # except those for column BAR
  $table->modify_tag('TD',{
      class => 'bar',
  }, 'bar');

The order of the execution of the previous two methods calls is
commutative - it doesn't matter.

A final caveat is setting the <CAPTION> tag. This one breaks
the signature convention:

  $table->modfify_tag('CAPTION', $value, $atr);

Since there is only one <CAPTION> allowed in an XHTML table,
there is no reason to bind it to a column or an area:

  # with attributes
  $table->modify_tag('caption','A Table Of Contents',{
      class => 'body',
  });

  # without attributes
  $table->modify_tag('caption','A Table Of Contents');

The only tag that cannot be modified by this method is the <COL>
tag. Use add_colgroup to add these tags instead.

=item B<add_colgroup>

  $table->add_colgroup($cols)

Add a new <COL> tag and attributes. The only argument is reference
to a hash that contains the attributes for this <COL> tag. Multiple
<COL> tags require multiple calls to this method. The <COLGROUP> tag
pair will be automatically generated if at least one <COL> tag is
added.

Advice: use <COL> and <COLGROUP> tags wisely, don't do this:

  # bad
  for (0..39) {
    $table->add_colgroup({
        foo => 'bar',
    });
  }

When this will suffice:

  # good
  $table->modify_tag('colgroup',{
      span => 40,
      foo  => 'bar',
  });

You should also consider using <COL> tags to set the attributes
of <TD> and <TH> instead of the <TD> and <TH> tags themselves,
especially if it is for the entire table:

  $table->add_colgroup({
      span  => $table->get_col_count(),
	  class => 'body',
  });

=item B<map_col>

  $table->map_col($subroutine,[$cols])

Map a supplied subroutine to all the <TD> tag's cdata for
the specified columns.  The first argument is a reference to a
subroutine. This subroutine should shift off a single scalar at
the beginning, munge it in some fasion, and then return it.
The second argument is the column or columns to apply this
subroutine to. Example: 

  # uppercase the data in column DEPARTMENT
  $table->map_col( sub { return uc shift }, 'department');

One temptation that needs to be addressed is using this method to
color the cdata inside a <TD> tag pair. Don't be tempted to do this:

  # don't be tempted to do this
  $table->map_col(sub {
    return qq|<font color="red">| . shift . qq|</font>|;
  }, 'first_name');

  # when this will work (and you dig CSS)
  $table->modify_tag({
	  style => 'Color: red;',
  }, 'first_name');

Another good candidate for this method is turning the cdata
into an anchor:

  $table->map_col(sub {
    my $raw = shift;
    return qq|<a href="/foo.cgi?process=$raw">$raw</font>|;
  }, 'category');
  
This method permantly changes the data, so use it wisely and
sparringly. This consequence will be removed in a future version.

=item B<set_row_colors>

  $table->set_row_colors([$colors],[$cols])

Assign a list of colors to the body cells for specified columns
or the entire table if none specified for the purpose of
alternating colored rows.  This is not handled in the same
way that B<modify_tag()> rotates the BGCOLOR attribute.
That method rotates on each column (think horizontally),
this one rotates on each row (think vertically). However:

  # this:
  $table->modify_tag('td',{
	  bgcolor => [qw(green green red red)],
  }, [qw(first_name last_name)]);

  # produces the same output as:
  $table->set_row_colors(
      [qw(green red)],
	  [qw(first_name last_name)],
  );

This is a strong possibiliy that this method will be deprecated to
make way for a method that handles any attribute, not just BGCOLOR.
If so, this method will just hand the arguments to the new method,
so as not to break any clients.

=item B<set_null_value>

  $table->set_null_value($new_null_value)

Change the default null_value (&nbsp;) to something else.

=item B<set_group>

  $table->set_group($column)

Assign one column as the main column. Every time a new row is
encountered for this column, a <TBODY> tag is written. An optional
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
pick album over song, since an album consists of songs.

=item B<calc_totals>

  $table->calc_totals([$cols],$mask)

Computes totals for specified columns. The first argument is the column
or columns to sum, again a scalar or array reference is the requirement.
Non-numbers will be ignored, negatives and floating points are supported,
but you have to supply an appropriate sprintf mask, which is the optional
second argument, in order for the sum to be correctly formatted. See
L<sprintf> for further details.  

=item B<calc_subtotals>

  $table->calc_subtotals([$cols],$mask)

Computes subtotals for specified columns. It is manditory that you
first specify a group via B<set_group()> before you call this method.
Each subtotal is tallied from the rows that have the same value
in the column that you specified to be the group. At this point, only
one subtotal can be calculated and displayed. Plans for implementing
N number of subtotals and groups are not on my list, but if enough
feedback is generated to warrent it, I will get to work. Better yet,
send me a patch. :)

=item B<get_col_count>

  $scalar = $table->get_col_count()

Returns the number of columns in the table.

=item B<get_row_count>

  $scalar = $table->get_row_count()

Returns the numbers of body rows in the table.

=back

=head1 TUTORIAL

This section provides a quick tutorial for you to
learn about the available methods and the somewhat
proper way to use them. For simplicity's sake, the
sample database table is nothing more than a glorified
flat file, but it will suffice:

  +----------------------+
  |Child    Parent   Take|
  +----------------------+
  |bugs     Mo         5 |
  |daffy    Larry      4 |
  |donald   Larry      4 |
  |porky    Curly      7 |
  |mickey   Mo         8 |
  |goofy    Curly      9 |
  |cartman  Mo         2 |
  +----------------------+

Call this table B<BAR>, and let's assign it to database
B<FOO>. The important thing to note about this table is
that one column is numbers, and the other two have a 1
to M relationship with each other (that is, one Parent
can have many Children). You will probably never encounter
a database table like this in production, but many of
the result sets returned by a database do have a similar
structure.

Step 1. Establish a connection to the database server.

Here is where the mileage varies. It is vital that you
understand that different databases handle different
arguments for connection. Read L<DBI> as well the one
for the DBD module you installed. 

For this example, assume that we are using MySql on
a server named deadbeef, and we can connect with the password
for user 'sparky' (the database is 'FOO'):

  my $table = DBIx::XHTML_Table->new(
    'DBI:mysql:FOO:deadbeef', 'sparky', '********'
  ) || die "could not connect to database\n";

Step 2. Execute a SQL query

Let's get all the rows, parent first, child second, the
take third, all ordered by parent, then child:

  $table->exec_query("
    SELECT PARENT,CHILD,TAKE
    FROM BAR
    ORDER BY PARENT,CHILD
  ");

Step 3. Mold an XHTML table

At this point, we have the means to retrieve a very basic XHTML
table. Everything will be displayed nice and lined up, but folks
want 'pretty bridges'. Start by modifying the <TABLE> tag:

  $table->modify_tag('TABLE',{
    border      => 2,
    cellspacing => 0,
    width       => '40%',
    rules       => 'groups',
    summary     => 'weekly takes',
  });

  print $table->get_table();

Add a caption:

  $table->modify_tag('CAPTION','This Weeks Takes');

  # to see this example progress from simple to complex,
  # add each of the following snippets (one at a time)
  # to your code, just before the call to get_table()

Let's sum up how much the kids took this week:

  $table->calc_totals('take');

The totals appear as the last row, in the FOOTER area.
Color that row and the HEADER row:

  $table->modify_tag('TH',{
    bgcolor  => '#98a898',
  }, [qw(header footer)]);

The duplicate names in the Parent's column is
annoying, you can pick one and only one column
to suppress duplicates on, via set_group():

  $table->set_group('parent',1);

Get a running subtotal of each of the kid's takes.
You can only calculate one subtotal that is based
off of the group you designated, Parent:

  $table->calc_subtotals('take');

More rows added to the BODY area. Change their color:

  $table->modify_tag('TH',{
    bgcolor  => '#a9b9a9',
  },'body');

Hmmm, now the take column looks off-balance, change
the aligment:

  $table->modify_tag('TD',{
    align  => 'center',
  },'take');

And finally, spice up the body rows with alternating colors:

  $table->set_row_colors(['#bacaba','#cbdbcb']);

Experiment, have fun with it. Go to PerlMonks and download
extremely's Web Color Spectrum Generator and use it suply
a list of colors to I<set_color>. You can find it at
	http://www.perlmonks.org/index.pl?node_id=70521

=head1 BUGS

Yes. But I prefer to call them features. See B<TODO>.

=head1 TODO

I consider this module to be 95% complete, all features
work and the orginal requirements were all completed.
However, I do not feel that is ready for a version of
1.0 just yet. Some more issues need to be addressed and
solved:

=over 4

=item Clean up calc_totals() and calc_subtotals()

These two methods wouldn't get a C from any college
level Computer Science II course. But they do work,
so I decided to include them in this release. Expect
to see these two refactored sometime in the future,
as well as the subroutine that uses the data they
create - B<_build_body()> As always, patches are
welcome. :)

=item Allow multiple groups

Only being able to set one group is limiting, but unless
there is a practicle need to do so, I probably won't 
bother implenting this one. Patches are welcome.

=item Give finer tuning on group colors

It might be nice to allow groups columns to only change
colors when the group changes, not just the row. I'll
be looking for a way to implement this cleany. And why
stop with colors?  The B<set_row_colors> probably should
be deprecated and a new method that handles any attribute
would be ideal.

=item Add a method to map subs to the titles

Just like B<map_col>, a new method that changes the
titles <TH> tag's cdata would be nice. For example,
changing the titles to anchor links that point back
to the CGI script a sort query variable set to the
name of the cdata. Instant front-end to sortable
reports.

=item Make B<map_col> behave itself

The previous item could be easily solved if B<map_col>
did not alter the original data.

=item Enclose body rows in <TBODY> and </TBODY>

Currently I am implementing grouping with single <TBODY/>
tags. This is perfectly legal, because the closing tag is
completely optional. But it seems to me that all rows
should be fully enclosed - however, the subroutine that
handles this, B<_build_body()>, is fairly 'cornered in'
and would reuquire some serious refactoring. Big thanks
to PerlMonk's "extremely" for pointing this out to me.

=back

=head1 CREDITS

=item Briac 'OeufMayo' PilprE<eacute> for the name

=item Mark 'extremely' Mills for guidence and suggestions

=item Matt Sergeant for DBIx::XML_RDB

=item Perl Monks for the education

=head1 SEE ALSO 

L<DBI>

=head1 AUTHOR 

Jeffrey Hayes Anderson <captvanhalen@yahoo.com>

=head1 COPYRIGHT

Copyright (c) 2001 Jeffrey Hayes Anderson. All rights reserved.
DBIx::XHTML_Table is free software; it may be copied, modified,
and/or redistributed under the same terms as Perl itself.

=cut
