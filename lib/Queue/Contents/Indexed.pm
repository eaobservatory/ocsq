package Queue::Contents::Indexed;

=head1 NAME

Queue::Contents::Indexed - Manipulate contents of an indexed queue

=head1 SYNOPSIS

  use Queue::Contents::Indexed;

  $q->curindex( 4 );

=head1 DESCRIPTION

This class provides methods for manipulating the contents
of an indexed queue. In an indexed queue the active queue element
is represented by an index into the queue array rather than
simply assuming that the first element is the current entry.

=cut

use 5.006;
use strict;
use warnings;
use base qw/ Queue::Contents /;

=head1 METHODS

The following methods are provided:

=head2 Constructors

=over 4

=item B<new>

This is the Contents constructor. Accepts an array of Queue::Entry
objects to initialise the Queue contents.

  $queue = new Queue::Contents::Indexed(@entries);

If an optional hash reference is supplied for the first argument,
this is deemed to contain options for the constructor.
Currently, no options are supported.

If no arguments are supplied the current index is undefined.
If arguments are supplied the current index is set to 0
(see C<loadq>).

=back

=head2 Accessor Methods

=over 4

=item B<curindex>

Index of the active entry.

  my $i = $q->curindex;
  $q->curindex( 4 );

When a new index is provided, it must lay in the range 0 to max index
(total number of elements minus 1). If it lies outside this range the
index will not be modified and the current index is returned.

Index must be an integer.

The current index will be undefined if the queue is empty.
If an attempt is made to undefine the current index when
the queue is not empty the attempt will fail.

The current index is automatically cleared (set to C<undef>) if the
method is invoked when the queue is empty. This means it should
never be required to set it to C<undef> explicitly.

If the current index is undefined but the queue has entries,
the current index will automatically be set to 0 when
the value is requested.

If a valid new index is supplied the lastindex() is not reset
to C<undef> (since lastindex() still refers to a valid entry).

=cut

sub curindex {
  my $self = shift;
  if (@_) {
    my $new = shift;
    if (defined $new) {
      if ($new =~ /^\d+$/ && $self->indexwithin($new) ) {
	# A number and it is in range
	$self->{CurIndex} = $new;
      }
    }
  } else {
    # if we were run without arguments and the queue has entry
    # but the index is undef, set it to zero
    if ($self->countq > 0 && ! defined $self->{CurIndex}) {
      $self->{CurIndex} = 0;
      $self->lastindex(undef);
    }
  }

  # undefine the index if needs be
  if ($self->countq == 0) {
    $self->{CurIndex} = undef;
    $self->lastindex(undef);
  }


  return $self->{CurIndex};
}

=back

=head2 General Methods

=over 4

=item B<incindex>

  $q->incindex;
  $q->incindex(4);

Increment the current queue index by the specified amount (1 by
default).  Returns true if the index was incremented.  The resultant
index can never be larger than the highest index of the queue but will
return false if the index can not be increased.

Increment must be positive integer.

If the index increment will force the index to exceed the maximum
allowed value the index will be set to the maximum value and the routine
will return true.

If the queue is empty the index is not changed (and the method returns
false). If the current index is undefined and the queue is not empty,
the index will be incremented as if the current index was -1. This
behaviour allows C<addback> and C<addfront> to work as expected.

=cut

sub incindex {
  my $self = shift;
  my $request = shift;

  # Get the current index and abort if the queue is empty
  my $cur = $self->curindex;
  my $countq = $self->countq;
  return 0 unless $countq > 0;

  # Queue is not empty but we have an undefined index
  # so set it to -1
  $cur = -1 unless defined $cur;

  # Default value if none supplied
  $request = 1 unless defined $request;

  # Return false if the increment is negative or zero
  return 0 if $request < 1;

  # We need to distinguish between the case where we
  # are already at the maxindex and can go no higher (return false)
  # AND the current index is not at the max but the
  # addition of the new increment will push the
  # index over the top (in which case the curindex should
  # be set to maxindex and we return true).
  # This ruins the compactness of this method since it forces
  # a load of index testing into here which was normally left
  # to curindex itself.
  my $max = $self->maxindex;
  my $new = $cur + $request;
  if ($cur == $max) {
    # Already at max value
    # No point going any further
    return 0;
  } elsif ($new - $max > 0) {
    # Adopt the new value
    $new = $max;
  }

  # Set the new value and check the return value
  # If the return value matches the new value
  # then we were successful
  # This test is pretty meaningless with the new index
  # range tests above but it doesnt hurt
  return ( $self->curindex($new) == $new ? 1 : 0);
}

=item B<decindex>

  $q->decindex;
  $q->decindex(10);

Decrement the current queue index by the specified amount (by 1 if no
argument specified). It can not be made smaller than zero. Returns
true if the index was modified, false otherwise.

Decrement must be positive integer.

If the index deccrement will force the index to be less than zero
the index will be set to zero and the routine will return true.

If the index is not defined (the queue is empty) the index
is not modified (and the method returns false).

=cut

sub decindex {
  my $self = shift;
  my $request = shift;

  # Get the current index and abort if it is not defined
  my $cur = $self->curindex;
  return 0 unless defined $cur;

  # Default value if none supplied
  $request = 1 unless defined $request;

  # Return false if the decrement is negative or zero
  return 0 if $request < 1;

  # We need to distinguish between the case where we
  # are already at the minindex and can go no lower (return false)
  # AND the current index is not at the min but the
  # subtraction of the new decrement will push the
  # index too low (in which case the curindex should
  # be set to minindex and we return true).
  # This ruins the compactness of this method since it forces
  # a load of index testing into here which was normally left
  # to curindex itself.
  my $min = 0;
  my $new = $cur - $request;
  if ($cur == $min) {
    # Already at min value
    # No point going any further
    return 0;
  } elsif ($min - $new > 0) {
    # Adopt the new value
    $new = $min;
  }

  # Set the new value and check the return value
  # If the return value matches the new value
  # then we were successful
  # This test is pretty meaningless with the new index
  # range tests above but it doesnt hurt
  return ( $self->curindex($new) == $new ? 1 : 0);

}

=item B<nextindex>

The index of the next entry. Returns undefined if the current
index position is at the end of the queue or if the current
index is itself undefined.

=cut

sub nextindex {
  my $self = shift;
  my $index = $self->curindex;
  return undef unless defined $index;
  $index++;
  return ( $self->indexwithin($index) ? $index : undef);
}

=item B<previndex>

The index of the previous entry. Returns undefined if the current
index position is at the start of the queue or if the current
index is itself undefined.

=cut

sub previndex {
  my $self = shift;
  my $index = $self->curindex;
  return undef unless defined $index;
  $index--;
  return ( $self->indexwithin($index) ? $index : undef);
}

=item B<cmpindex>

Compare the supplied index with the current position of the index.

  $cmp = $q->cmpindex( $index );

Returns 1 (if the supplied index is greater than the current index), 0
(if the indexes are the same) or -1 (if the supplied index is smaller
than the current index).

Returns C<undef> if the current index is not defined.

=cut

sub cmpindex {
  my $self = shift;
  my $index = shift;
  my $cur = $self->curindex;
  return undef unless (defined $index && defined $cur);
  return ( $index <=> $cur );
}


=item B<curentry>

Retrieve the currently selected entry.

  $entry = $q->curentry;

Returns C<undef> if the queue is empty.

=cut

sub curentry {
  my $self = shift;
  my $index = $self->curindex;
  return undef unless defined $index;
  return $self->contents->[$index];
}

=item B<nextentry>

Retrieve the entry following the currently selected entry.
Returns C<undef> if no more entries are available.

=cut

sub nextentry {
  my $self = shift;
  my $index = $self->nextindex;
  return ($index ? $self->contents->[$index] : undef);
}

=item B<preventry>

Retrieve the entry preceding the currently selected entry.
Returns C<undef> if no more entries are available.

=cut

sub preventry {
  my $self = shift;
  my $index = $self->previndex;
  return ($index ? $self->contents->[$index] : undef);
}


=item B<loadq>

Load entries onto the queue. Always overwrites previous
entries.

  $q->loadq( @entries );

Method checks that each element in the array is a C<Queue::Entry>
object. If an element is not of the correct class a warning
is issued and the element is not stored.

The current index is always reset to 0.

=cut

sub loadq {
  my $self = shift;

  # Add the entries
  $self->SUPER::loadq(@_);

  # And reset the index
  $self->curindex(0);

  return;
}

=item B<clearq>

Clear the queue and set the current index to C<undef>.

  $q->clearq;

=cut

# base class is fine since curindex will automatically
# set the curindex to undef once the queue is empty.

=item B<cutq>

Permanently remove entries from the queue.

  @cut_entries = $q->cutq($startindex, $num);

Removes C<$num> entries starting at position C<$startindex>.
If the current index is less than C<$startindex> the
current index is not changed. If the current index is within
the range removed the current index is set to the entry now
at C<$startindex> (or the end of the queue if the elements
were removed from the end). If the current index is above the
region removed, the current index is modified such that the
same entry is highlighted.

If the second argument is left out only a single item
is cut from the queue. If the second argument is less than
one nothing happens. If the start index is out of range
then nothing happens.

If the current index corresponds to one of the entries that was cut
I<and> this entry was removed from the end of the queue, then the
current index will be set to a value outside of the queue.

=cut

sub cutq {
  my $self = shift;
  my $startindex = shift;
  my $num = shift;

  # Get the current index value
  # before the cur
  my $cur = $self->curindex;

  # We need to go through each MSB that will be affected 
  # and register the current entry with it. This requires that
  # we duplicate the code for defaulting $num...
  # Problem is that the base class does the actual MSB cut
  $num = 1 unless defined $num;
  if ($num > 0) {
    my $max = $self->maxindex;
    # If max is not defined we probably have an empty queue
    if (defined $max) {
      my $end = $startindex + $num - 1;
      $end = ( $end > $max ? $max : $end  );
      my %msbs;
      for my $i ($startindex .. $end) {
	my $entry = $self->getentry( $i );
	# For efficiency just find each MSB object
	my $msb = $entry->msb;
	next unless defined $msb;
	$msbs{ $msb } = $msb unless exists $msbs{$msb};
      }
      # Now register the current entry
      my $cur = $self->curentry;
      for my $msb (values %msbs) {
	$msb->refentry( $cur );
      }
    }
  }

  # Do the cut
  my @cut = $self->SUPER::cutq($startindex, $num);

  # Decide whether the index should change
  if (@cut) {
    # Calculate the index of the last thing to be removed
    my $endindex = $startindex + scalar(@cut) - 1;

    # Decide whether we will need to change curindex
    # Can not use cmpindex since we have the complication
    # of endindex
    my $newcur;
    if ($cur <= $startindex) {
      # No effect
      $newcur = $cur;
    } elsif ($cur > $startindex && $cur <= $endindex) {
      # Curindex must be set to the startindex
      $newcur = $startindex;
    } else {
      # Curindex must be decremented by the number of entries
      # removed [not necessarily the same as $num if we removed
      # from the end of the queue]
      $newcur = $cur - scalar(@cut);
    }

    # Set the new index
    $self->curindex( $newcur );
  }

  return @cut;
}

=item B<cutmsb>

Remove all entries associated with the MSB in which the specified
entry is a member. If no index is specified, assumes the current index.

  @removed = $q->cutmsb();
  @removed = $q->cutmsb( $index );

=cut

sub cutmsb {
  my $self = shift;
  my $refindex = shift;
  $refindex = $self->curindex unless defined $refindex;
  return $self->SUPER::cutmsb( $refindex );
}

=item B<addback>

Add some entries to the back of the queue. The index
will not be modified unless the queue was empty prior
to invoking this method (in which case the index will be
set to 0).

=cut

sub addback {
  my $self = shift;
  my @entries = @_;

  # Get the initial count
  my $count = $self->countq;

  # Use base class
  $self->SUPER::addback(@entries);

  # Increment index if the queue was empty
  # Not really needed since the index will automatically
  # set itself to 0
  $self->curindex(0)
    if $count == 0;

  return;
}

=item B<addfront>

Add some entries to the front of the queue. The index
is modified such that the same entry is selected before
and after this call.

  $q->addfront(@entries);

Works with an empty queue.

=cut

sub addfront {
  my $self = shift;
  my @entries = @_;

  # Use base class
  $self->SUPER::addfront(@entries);

  # Increment index
  $self->incindex(scalar(@entries));

  return;
}


=item B<shiftq>

Removes the entry from position 0 and returns that entry.

  $top = $q->shiftq;

This is similar to the Perl shift() command.
The current index is decremented by 1.

Returns undef if the queue is empty.

=cut

sub shiftq {
  my $self = shift;
  # shift automatically returns undef in empty array
  my $old = $self->SUPER::shiftq;
  $self->decindex;
  return $old;
}


=item B<popq>

Removes the entry from the last position in the queue and returns
it.

 $bottom = $q->popq;

This is similar to the Perl pop() command.

The current index is incremented if the index was at the end of the queue.

Returns C<undef> if the queue is empty.

=cut

sub popq {
  my $self = shift;
  my $cur = $self->curindex;
  return unless defined $cur;
  my $max = $self->maxindex;

  # Use the base method
  my $bot = $self->SUPER::popq;

  # Change the index if the old current index was the
  # same as the old max
  $self->curindex( $self->maxindex)
    if $cur == $max;

  return $bot;
}

=item B<insertq>

Insert elements into the queue at the specified index.

  $q->insertq(4, @entries);

If the current index is less than the insertion point it is
not changed. If the current index is greater than or equal
to the insertion point the current index is incremented by
the number of entries.


=cut

sub insertq {
  my $self = shift;
  my ($pos, @entries) = @_;

  # Get the current index
  my $cur = $self->curindex;

  # Do the insertion
  $self->SUPER::insertq($pos, @entries);

  # Modify the index if necessary
  # Depends on whether the base class method
  # invoked modified it via addback or addfront
  # Need to change it if the index is the same
  # as it was before and if the current index was
  # larger than the specified position
  # Calculate whether need to increment it
  # Do not need to touch it (handled by addback)
  # if the queue was empty prior to the insertion
  if (defined $cur) {
    if ( $cur >= $pos ) {
      # in principal it should be different
      # Get the new value
      my $newcur = $self->curindex;

      # If the new index is the same as the old
      # we need to fix it up (newcur can not be undef
      # if cur was defined)
      if ($newcur == $cur) {
	$self->incindex( scalar(@entries) );
      }
    }
  }

  return;
}

=item B<get_for_observation>

Retrieve the queue entry that should be sent for observation.
Returns the entry at the position of the highlight.

=cut

sub get_for_observation {
  my $self = shift;
  $self->lastindex( $self->curindex );
  return $self->curentry;
}

=item B<remaining_time>

Time remaining on the queue. Returns the sum of all the entries from
the currently selected entry to the end of the queue.

  $time = $q->remaining_time;

Returns a Time::Seconds object.

=cut

sub remaining_time {
  my $self = shift;

  my $time = new Time::Seconds(0);
  my $cur = $self->curindex;
  return $time if !defined $cur;

  for my $i ($cur .. $self->maxindex) {

    my $e = $self->getentry( $i );
    my $t = $e->duration;
    $time += $t if defined $t;
  }

  return $time;
}

=back

=head1 SEE ALSO

L<Queue>, L<Queue::Contents>, L<Queue::Entry>

=head1 AUTHOR

Tim Jenness E<lt>t.jenness@jach.hawaii.eduE<gt>
(C) 2002 Particle Physics and Astronomy Research Council.
All Rights Reserved.

=cut

1;
