package Queue::Contents;

=head1 NAME

Queue::Contents - Manipulate queue contents

=head1 SYNOPSIS

  use Queue::Contents;

  $Q = new Queue::Contents;

  @description = $Q->stringified;

=head1 DESCRIPTION

This class provides methods for manipulating the contents of a Queue.
The Queue manipulates Queue::Entry objects.

In essence all queue are just arrays of Queue::Entry objects. The
difference lies in the selection of the active element and whether
cut/paste operations are supported.

=cut

use 5.006;
use strict;
use Carp;
use warnings;

=head1 METHODS

=head2 Constructors

=over 4

=item B<new>

This is the Contents constructor. Accepts an array of Queue::Entry
objects to initialise the Queue contents.

  $queue = new Queue::Contents(@entries);
  $queue = new Queue::Contents(\%options, @entries);

Entries are loaded using the C<loadq> method.
If an optional hash is supplied as first argument it is
used to initialise the hash (by running methods of the same
names as the keys).

=cut

sub new {
  my $proto = shift;
  my $class = ref($proto) || $proto;

  # Check for optional options hash
  my %options = ();
  %options = %{ shift() } if (@_ && ref($_[0]) eq 'HASH');

  # Create anon hash for class
  my $q = {};

  # Initialise
  $q->{Contents} = [];

  # Bless into the correct class
  bless ($q, $class);

  # Now initialise queue with the options hash
  for my $key (keys %options) {
    my $method = lc($key);
    $q->$method($options{$key}) if $q->can($method);
  }

  # Deal with arguments
  $q->loadq(@_) if @_;

  return $q;
}


=head2 Accessor Methods

=over 4

=item B<contents>

Returns an array containing the current contents of the Queue
(when called in a array context). When called in a scalar context
the reference to the array is return. Note that the Queue contains
Queue::Entry objects.

  @entries = $queue->contents;
  $ref = $queue->contents;

If arguments are supplied, the entire contents of the queue are replaced
with the supplied values (using C<loadq>). [This is preferable to
simply using the array reference since loadq will check the type
of each element being added to make sure it is an array of Entry
objects].

  $queue->contents(@entries);

=cut

sub contents {
  my $self = shift;
  if (@_) {
    # Clear queue and add the supplied arguments to it
    $self->loadq(@_);
  }

  # Check the context
  if (wantarray) {
    return @{$self->{Contents}};
  } else {
    return $self->{Contents};
  }

}

=back

=head2 General Methods

=over 4

=item B<countq>

Return number of elements in the queue.

  $num = $q->countq;

=cut

sub countq {
  my $self = shift;
  my $contents = $self->contents;
  my $index = $#$contents;
  return ($index + 1);
}

=item B<indexwithin>

Does the supplied array index refer to an entry in the queue?

  $isok = $q->indexwithin( $index );

Returns true if the index is within the allowed range, false
otherwise.

=cut

sub indexwithin {
  my $self = shift;
  my $index = shift;

  return 0 unless defined $index;
  my $maxindex = $self->maxindex;
  return 0 unless defined $maxindex;

  return ($index > -1 and $index <= $maxindex )
}

=item B<maxindex>

Return the maximum allowed array index.

  $max = $q->maxindex;

Returns C<undef> if the queue is empty.

=cut

sub maxindex {
  my $self = shift;
  my $count = $self->countq;
  my $maxindex = ( $count > 0 ? $count - 1 : undef);
  return $maxindex;
}

=item B<loadq>

Load an array of entry objects on to the queue. Effectively the same
as C<clearq> followed by C<addback>.

  $q->loadq(@entries);

Same behaviour as simply supplying arguments to the C<contents> method
with the bonus of checking the supplied arguments.

=cut

sub loadq {
  my $self = shift;
  $self->clearq;
  $self->addback( @_ );
}

=item B<clearq>

Clear the contents of the queue. Reset the queue contents.
No arguments are allowed.

  $queue->clearq;

=cut

sub clearq {
  my $self = shift;
  @{$self->contents} = ();
}

=item B<cutq>

Cut entries from the queue.

  @cut_entries = $queue->cutq($start, $num)

The entries cut from the queue are returned to the caller.  The
supplied arguments are the start position (start counting from zero)
and the number of entries to cut from the queue. This command is
similar to the Perl splice() command.

If the second argument is left out only a single item
is cut from the queue. If the second argument is less than
one nothing happens. If the start index is out of range
then nothing happens.

=cut

sub cutq {
  my $self = shift;
  my $startindex = shift;
  my $num = shift;
  $num = 1 unless defined $num;

  # Check the range for the cut number and index
  return unless $num > 0;
  return unless $self->indexwithin( $startindex );

  # Cut the entries from the queue
  return splice(@{$self->contents}, $startindex, $num);
}


=item B<addback>

Add Queue::Entry objects to the back of the queue.
An array of objects can be supplied.

  $queue->addback(@entries);

This is similar to the Perl push() command except that the
type of each entry is checked to make sure that it isa
Queue::Entry object. If supplied contents are not Queue:Entry
objects they are ignored but a warning message is printed if
warnings are turned on (ie $^W = 1).

=cut

sub addback {
  my $self = shift;
  if (@_) {
    my @new = grep { $self->_test_type($_) } @_;
    push(@{$self->contents}, @new);
  }
  return;
}

=item B<addfront>

Add Queue::Entry objects to the front of the queue.
An array of objects can be supplied.

  $queue->addfront(@entries);

This is similar to the Perl unshift() command except that the
type of each entry is checked to make sure that it isa
Queue::Entry object. If supplied contents are not Queue:Entry
objects they are ignored but a warning message is printed if
warnings are turned on (ie $^W = 1).

All the entries are added in order.

=cut

sub addfront {
  my $self = shift;
  if (@_) {
    my @new = grep { $self->_test_type($_) } @_;
    unshift(@{$self->contents}, @new);
  }
  return;
}


=item B<shiftq>

Shift the top entry of the queue.

  $top = $queue->shiftq;

This is similar to the Perl shift() command.

=cut

sub shiftq {
  my $self = shift;
  return shift(@{$self->contents});
}

=item B<popq>

Retrieves the last member of the queue (removing it from the queue
in the process). This is similar to the Perl pop() command.

  $bottom = $queue->popq;

=cut

sub popq {
  my $self = shift;
  return pop(@{$self->contents});
}

=item B<insertq>

Insert entries into the middle of the queue (at the specified
index position).

  $q->insertq(4,@entries);

If the specified position is greater than or equal to the maximum
allowed array index, the entries are sent to C<addback>.

If the specified position is 0 or less the entries are sent
to C<addfront>.

If the queue is empty the entries are simply added to the queue
using C<addback> regardless of the supplied index.

=cut

sub insertq {
  my $self = shift;

  # Read the first arg
  my $pos = shift;

  # If the queue is empty or if the supplied index is >= max
  # simply call addback
  if ($self->countq == 0 || $pos >= $self->maxindex) {
    # add the elements to the back of the queue
    $self->addback(@_);
  } elsif ($pos <=0) {
    # add the elements to the front of the queue
    # if the pos is 0 or negative
    $self->addfront(@_);
  } else {
    # Do the splice
    # Get the entries to insert (test type)
    my @paste = grep {$self->_test_type($_) } @_;

    # Now splice the array into the main Q contents
    splice(@{$self->contents}, $pos, 0, @paste);
  }

  return;
}


=item B<get_for_observation>

Retrieve the queue entry that should be sent for observation.
By default the top entry is shifted off the array.

=cut

sub get_for_observation {
  my $self = shift;
  return $self->shiftq
}

=item B<post_obs_tidy>

Runs code that should occur after the observation has been completed
but before the next observation is requested.

In the base class this does nothing. In an indexed subclass this
may increment the index.

=cut

sub post_obs_tidy {
  my $self = shift;
  return;
}

=back

=head2 Display Methods

=over 4

=item B<stringified>

Returns back an array of strings describing the contents of the
queue using descriptive strings. This can be used for displaying
the queue contents in a text-based environment.
Returns an array reference when called in a scalar context.

=cut

sub stringified {
  my $self = shift;

  # Loop over all entries storing string version of entry
  my @strings;
  foreach ($self->contents) {
    push(@strings, $_->string);
  }

  if (wantarray) {
    return @strings;
  } else {
    return \@strings;
  }

}

=back

=head2 Private Methods

=over 4

=item B<_test_type>

Test that the queue entry is of the correct type.
Returns true or false.

  $isok = $q->_test_type( $entry );

Currently makes sure that entries are of type C<Queue::Entry>.

Warns if the entry is not of the correct type.

=cut

sub _test_type {
  my $self = shift;
  my $ent = shift;
  if (UNIVERSAL::isa($ent, 'Queue::Entry')) {
    return 1;
  } else {
    warn "Argument supplied to queue [$ent] is not a Queue::Entry object - ignoring\n" if $^W;
    return 0;
  }


}

=back

=head1 SEE ALSO

L<Queue>, L<Queue::Contents::Stack>, L<Queue::Entry>

=head1 AUTHOR

Tim Jenness E<lt>t.jenness@jach.hawaii.eduE<gt>
(C) 1999-2002 Particle Physics and Astronomy Research Council.
All Rights Reserved.

=cut


1;
