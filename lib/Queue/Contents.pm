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
use Time::Seconds;

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

=back

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

=item B<lastindex>

Index of last entry retrieved from the queue via C<get_for_observation>.

Undefined by default and if the queue contents are changed.
It is not modified if the index is changed (this allows you to compare
the current index with that of the observation just sent).

Used to determine whether anything was modified between sending and
dealing with the aftermath.

An attempt is made to keep lastindex() current (as is done for
curindex()) in order to keep track of the same entry. This allows you
to make sure you are still using the same entry even if some new
entries have been inserted into the queue.

=cut

sub lastindex {
  my $self = shift;
  if (@_) { $self->{LastIndex} = shift; }
  return $self->{LastIndex};
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

=item B<getentry>

Retrieve the entry with the specified index.

  $entry = $q->getentry( $index );

Returns C<undef> if the index is out of range.

=cut

sub getentry {
  my $self = shift;
  my $index = shift;
  return undef unless $self->indexwithin($index);
  return $self->contents->[$index];
}

=item B<getindex>

Retrieve the index associated with the specified entry
(assuming each entry on the queue is a unique object).

  $index = $q->getindex( $entry );

Returns C<undef> if the entry is not in the queue.

=cut

sub getindex {
  my $self = shift;
  my $entry = shift;

  # Get all the contents
  my @c = $self->contents;

  # loop over the queue
  my $index;
  for my $i (0..$#c) {
    if ($c[$i] == $entry) {
      $index = $i;
      last;
    }
  }

  return $index;
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
  $self->lastindex(undef);
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

If the lastindex is defined and refers to one of the entries that
was cut it is reset.

=cut

sub cutq {
  my $self = shift;
  my $startindex = shift;
  my $num = shift;
  $num = 1 unless defined $num;

  # Check the range for the cut number and index
  return unless $num > 0;
  return unless $self->indexwithin( $startindex );

  # reset lastindex if we are in the cut region
  # or after the cut region
  my $last = $self->lastindex;
  if (defined $last) {
    if ($last > ($startindex+$num-1)) {
      $self->lastindex( $last - $num);
    } elsif ($last >= $startindex && $last <= ($startindex+$num-1)) {
      $self->lastindex(undef);
    }
  }

  # Cut the entries from the queue
  my @removed =  splice(@{$self->contents}, $startindex, $num);

  # We now have to remove these entries from the associated MSB object
  # so that we can correctly track changes to the start and end
  # of an MSB and whether we should be requesting that an MSB be
  # marked as completed [if a whole MSB were to be removed]
  # Rather than call the MSB method for each entry we group them
  # by MSB object
  my %msbs;
  for (@removed) {
    my $msb = $_->msb;
    next unless defined $msb; # this is not part of an MSB
    if (!exists $msbs{$msb}) {
      $msbs{$msb} = [];
    }
    push(@{$msbs{$msb}}, $_);
  }

  # Now loop over all the MSB objects
  for (keys %msbs) {
    my $msb = $msbs{$_}->[0]->msb;
    $msb->cut( @{ $msbs{$_} });
  }

  # return the entries
  return @removed;
}

=item B<cutmsb>

Remove all entries associated with the MSB pointed to by the
entry at the specified index position.

  @removed = $q->cutmsb( $index );

Calibrations that have been inserted into the MSB are also removed.
If the specified index position does not correspond to an MSB ODF
then only that entry is removed.

Returns all the entries that were removed.

Does nothing if an index has not been specified or is out of range.

=cut

sub cutmsb {
  my $self = shift;
  my $refindex = shift;
  return unless defined $refindex;

  # Get the entry at this position.
  my $entry = $self->getentry( $refindex );
  return unless defined $entry;

  # See if we are associated with an MSB
  my $msb = $entry->msb;

  # variables to store the start index for the real cut
  my ($startindex, $num);

  # if we do not have an MSB then we just cut this entry
  if (!$msb) {
    $startindex = $refindex;
    $num = 1;

  } else {
    # Have to get the first and last entry from the MSB and
    # translate that to an index
    my $first = $msb->entries->[0];
    my $last  = $msb->entries->[-1];

    # Translate to an index
    $startindex = $self->getindex( $first );
    my $lastindex = $self->getindex( $last );

    # calculate how many to cut
    $num = $lastindex - $startindex + 1;

  }

  # Now run the cut method
  return $self->cutq( $startindex, $num );
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

    # correct lastindex
    my $last = $self->lastindex;
    if (defined $last) {
      $last += scalar(@new);
      $self->lastindex($last);
    }
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

  # correct lastindex
  my $last = $self->lastindex;
  if (defined $last) {
    $last--;
    $self->lastindex($last);
  }

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

If the specified position is greater than the maximum
allowed array index, the entries are sent to C<addback>.

If the specified position is equal to the maximum position
the new entries are inserted at that position such that the
entry that was at the end is still at the end.

If the specified position is 0 or less the entries are sent
to C<addfront>.

If the queue is empty the entries are simply added to the queue
using C<addback> regardless of the supplied index.

lastindex() is kept up-to-date.

=cut

sub insertq {
  my $self = shift;

  # Read the first arg
  my $pos = shift;

  # If the queue is empty or if the supplied index is >= max
  # simply call addback
  if ($self->countq == 0 || $pos > $self->maxindex) {
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

    # correct lastindex
    my $last = $self->lastindex;
    if (defined $last) {
      if ($last >= $pos) {
	$last += scalar(@paste);
	$self->lastindex($last);
      }
    }

  }

  return;
}

=item B<replaceq>

Replace an entry with a new entry at the specified index position.

  $q->replaceq(4,$entry);

Returns true if successfull, else if the specified position is not in
range or the entry is not of the correct type, returns false.

lastindex() is reset I<if> it equals the entry that was replaced.

=cut

sub replaceq {
  my $self = shift;

  # Read the first arg
  my $pos = shift;
  my $entry = shift;

  if ($self->indexwithin($pos)) {
    return 0 unless $self->_test_type($entry);

    # Change the MSB membership
    my $oldentry = $self->getentry($pos);
    if ($oldentry->msb) {
      $oldentry->msb->replace( $oldentry, $entry);
    }

    # Replace the entry
    $self->contents->[$pos] = $entry;

    # reset lastindex if need be
    my $last = $self->lastindex;
    if (defined $last) {
      if ($pos == $last) {
	$self->lastindex(undef);
      }
    }

  } else {
    return 0;
  }

  return 1;
}

=item B<propsrc>

Propogate source information from the specified index to subsequent
entries that are missing target information.

  $c->propsrc( $index );

The propagation stops for the following two conditions:

 1. We hit an entry that has a valid target
 2. Once we hit a calibration observation we continue
    to propogate until we are no longer doing calibrations.
    This allows us to propogate through a set of 6 scan maps.

This should probably not need to know about the iscal method in "entity".
An entry should probably be modified to no about calibrations.

=cut

# KLUGE

sub propsrc {
  my $self = shift;
  my $index = shift;
  my $entry = $self->getentry($index);
  return unless $entry;

  my $c = $entry->getTarget;

  # do not check the current observation although we can set
  # the "foundcal" flag if the current observation is a cal
  # observation
  $index++;
  my $foundcal = 0;
  $foundcal = 1 if $entry->entity->iscal;
  #print "On entry: foundcal   = $foundcal\n";
  #print "Ref entry: " . $entry->string ."\n";

  while (defined( my $thisentry = $self->getentry($index) ) ) {

    # if we have a target abort from search
    last if $thisentry->getTarget;

    # if we have a calibrator flag this fact
    # if we did have a calibrator and have now not got one
    # we abort
    if ($thisentry->entity->iscal) {
      $foundcal = 1;
      # print "Found a calibrator: " . $thisentry->string."\n";
    } elsif ($foundcal) {
      # we have already found a calibrator and now we have not
      # got one so we stop here
      #print "Found cal is true but this entry is not a cal so stop\n";
      #print $thisentry->string ."\n";
      last;
    } else {
      #print "This is not a calibrator: " .$thisentry->string ."\n";
    }

    # set the target
    $thisentry->setTarget( $c );

    $index++;
  }

}

=item B<clear_target>

Remove the target information from the specified entry.

  $c->clear_target( $index )

=cut

sub clear_target {
  my $self = shift;
  my $index = shift;
  my $entry = $self->getentry($index);
  return unless $entry;
  $entry->clearTarget;
}

=item B<get_for_observation>

Retrieve the queue entry that should be sent for observation.
By default the top entry is shifted off the array.

=cut

sub get_for_observation {
  my $self = shift;
  return $self->shiftq
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

=item B<remaining_time>

Total (estimated) time remaining on the queue.

  $time = $q->remaining_time();

Returns a Time::Seconds object. For the base class, simply adds
up all the entries on the queue.

=cut

sub remaining_time {
  my $self = shift;

  my $time = new Time::Seconds(0);
  for my $e ($self->contents) {

    my $t = $e->duration;
    $time += $t if defined $t;

  }

  return $time;
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
    $ent = "undefined value" unless $ent; 
    warn "Argument supplied to queue [$ent] is not a Queue::Entry object - ignoring\n" if $^W;
    return 0;
  }


}

=back

=head1 SEE ALSO

L<Queue>, L<Queue::Contents::Stack>, L<Queue::Entry>

=head1 AUTHOR

Tim Jenness E<lt>t.jenness@jach.hawaii.eduE<gt>
Copyright (C) 1999-2002 Particle Physics and Astronomy Research Council.
All Rights Reserved.

=cut


1;
