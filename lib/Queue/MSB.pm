package Queue::MSB;

=head1 NAME

Queue::MSB - A collection of entries that form a single observing block

=head1 SYNOPSIS

  use Queue::MSB;

  $msb = new Queue::MSB( msbid => $id,
			 projectid => $proj,
			 entries => \@entries );

  $msb->cut( $entry );

=head1 DESCRIPTION

This class provides a mean of grouping entries in a Queue::Contents
object into a single MSB (an MSB is defined as consisting of all ODFs
added to the queue front or back in a single operation except for
those ODFs added as part of an insert into the middle of the queue).

=cut

use 5.006;
use strict;
use warnings;
use Carp;
use Time::HiRes qw/ gettimeofday /;

use vars qw/ $VERSION /;
$VERSION = '0.01';

=head1 METHODS

=head2 Constructors

=over 4

=item B<new>

This is the MSB constructor. Takes a hash argument
containing the MSBID, project ID and the entries that
form part of the MSB.

  $msb = new Queue::MSB( projectid => 'm02bu105',
			 msbid => '00af',
			 entries => \@entries
		       );

=cut

sub new {
  my $proto = shift;
  my $class = ref($proto) || $proto;

  # Read the arguments
  my %args = @_;

  # Create and bless
  my $msb = bless {
                   ProjectID => undef,
                   MSBID => undef,
                   Entries => [],
                   HasBeenObserved => 0,
                   HasBeenCompleted => 0,
                   MSBComplete => undef,
                   RefEntry => undef,
                   QID => undef,
                   TransID => undef,
                  }, $class;

  # Go through the input args invoking relevant methods
  for my $key (keys %args) {
    my $method = lc($key);
    if ($msb->can($method)) {
      # Return immediately if an accessor methods
      # returns undef (unless it was given undef)
      my $retval = $msb->$method( $args{$key});
      return undef if (!defined $retval && defined $args{$key});
    }
  }

  # Calculate a transaction ID (if required)
  $msb->_calc_transid();

  # Now update the first and last obs settings
  $msb->update;

  return $msb;

}

=back

=head2 Accessor Methods

=over 4

=item B<projectid>

The project ID associated with this MSB.

  $project = $msb->projectid;
  $msb->projectid( $project );

=cut

sub projectid {
  my $self = shift;
  if (@_) {
    $self->{ProjectID} = uc(shift);
  }
  return $self->{ProjectID};
}

=item B<msbid>

The MSB ID associated with this MSB.

  $msbid = $msb->msbid;
  $msb->msbid( $msbid );

=cut

sub msbid {
  my $self = shift;
  if (@_) {
    $self->{MSBID} = shift;
  }
  return $self->{MSBID};
}

=item B<transid>

The transaction ID associated with this MSB.

  $tid = $msb->transid;
  $msb->transid( $tid );

=cut

sub transid {
  my $self = shift;
  if (@_) {
    $self->{TransID} = shift;
  }
  return $self->{TransID};
}

=item B<queueid>

The queue ID associated with this MSB.

  $qid = $msb->queueid;
  $msb->projectid( $qid );

This is used to allow each MSB to be given a unique identifier
to make it easier for users to track them. Will usually be a number
that increments through the night.

=cut

sub queueid {
  my $self = shift;
  if (@_) {
    $self->{QID} = uc(shift);
  }
  return $self->{QID};
}


=item B<entries>

The queue entries associated with this MSB.  When called in a scalar
context the reference to the array is returned. Note that the
Queue::MSB contains Queue::Entry objects.

  @entries = $msb->entries;
  $ref = $msb->entries;

If arguments are supplied, the entire contents of the MSB are replaced
with the supplied values. A list or reference is supported. Each entry
is checked for type.

  $msb->entries(@entries);
  $msb->entries(\@entries);

Makes sure that each entry has this MSB associated with it
(via the C<msb> method). Additionally, each entry is configured
with a MSB transaction ID.

=cut

sub entries {
  my $self = shift;

  if (@_) {

    # see if we have an array
    my @entries;
    if (ref($_[0]) eq 'ARRAY' ) {
      @entries = @{ $_[0] };
    } else {
      @entries = @_;
    }

    # Now check each entry
    for my $src (@entries) {
      if (!UNIVERSAL::isa($src, "Queue::Entry")) {
        croak "Must supply MSB queue object with Queue::Entry objects";
      }
    }

    # Store them
    @{ $self->{Entries} } = @entries;

    # we have entries set so we can now calculated a transaction ID
    $self->_calc_transid();

    # Go through each entry and associate it with this msb
    # and force the transaction ID
    for (@entries) {
      $_->msb( $self );
      $_->msbtid( $self->transid );
    }

  }

  if (wantarray) {
    return @{ $self->{Entries} };
  } else {
    return $self->{Entries};
  }

}

=item B<refentry>

The entry corresponding to the currently highlighted entry in the
queue. If this entry (see Queue::Contents::Indexed->curentry) 
corresponds to an entry that has been removed from the MSB
using C<cut> then this may trigger the C<msbcomplete> callback
if there are no more entries on the queue.

  $ref = $msb->refentry;

Care must be taken to keep this value up-to-date as it is not
directly linked to the Queue::Contents object. [The Queue::MSB
does not know anything about the Queue::Contents]. The reason
for this disconnected-ness is that the C<cut> method is generally
executed after the current index has been manipulated by the
queue cut.

=cut

sub refentry {
  my $self = shift;
  if (@_) {
    $self->{RefEntry} = shift;
  }
  return $self->{RefEntry};
}

=item B<hasBeenObserved>

Indicate that at least one ODF in the MSB has been successfully observed.
This is important when deciding what to do when the MSB is cut or
the last observation has been cut.

  $obsd = $msb->hasBeenObserved();

=cut

sub hasBeenObserved {
  my $self = shift;
  if (@_) {
    $self->{HasBeenObserved} = shift;
  }
  return $self->{HasBeenObserved};
}

=item B<hasBeenCompleted>

Indicates that the MSB has been completed (in the sense that the 
C<msbcomplete> callback has been invoked).

  $cmpl = $msb->hasBeenCompleted();

=cut

sub hasBeenCompleted {
  my $self = shift;
  if (@_) {
    $self->{HasBeenCompleted} = shift;
  }
  return $self->{HasBeenCompleted};
}

=item msbcomplete

This is a callback invoked when the
the current MSB has been fully observed (usually triggered
when the last MSB entry is completed but can also be triggered
when the MSB has been cut).

  $handler = $msb->msbcomplete;
  $msb->msbcomplete(sub {print "Done"});

The callback is passed in the C<Queue::MSB> object (from which the
project ID and MSBID can be obtained).

=cut

sub msbcomplete {
  my $self = shift;
  $self->{MSBComplete} = shift if @_;
  return $self->{MSBComplete};
}



=back

=head2 General Methods

=over 4

=item B<update>

Ensure that the first ODF in the MSB is marked as the first
observation and that the last is marked as the last observation
(this can change when entries are cut or when the object entries
have been updated).

  $msb->update;

=cut

sub update {
  my $self = shift;

  # Get all the entries
  my $entries = $self->entries;

  # clear all the flags [this is probably irrelevant if
  # we never add things to the start or end but only remove
  for (@$entries) {
    $_->lastObs( 0 );
    $_->firstObs( 0 );
  }

  # Now force the correct state for the start and end
  if (scalar(@$entries)) {
    $entries->[-1]->lastObs( 1 );
    $entries->[0]->firstObs( 1 );
  }

  return;
}

=item B<completed>

Run a callback (retrieved via C<msbcomplete>) indicating that
the MSB has been completed. For example, triggering a popup asking
whether the MSB should be accepted or rejected. The callback
is passed in the MSB object.

This method will run the callback I<even if the MSB has not been
observed>.

Sets C<hasBeenCompleted> to true. It will not be run if the callback
has already been invoked (i.e. if C<hasBeenCompleted> is true).

=cut

sub completed {
  my $self = shift;
  my $cb = $self->msbcomplete;

  if ($cb && !$self->hasBeenCompleted) {
    # Need projectid and MSBId
    $cb->( $self );
    $self->hasBeenCompleted(1);
  }

  return;
}

=item B<getindex>

Retrieve the (internal) array index associated with the supplied
entry.

 $index = $msb->getindex( $entry );

Returns undef if the supplied entry can not be located in the
MSB entries. Assumes the MSB contains unique entries.

=cut

sub getindex {
  my $self = shift;
  my $refentry = shift;

  # Get all the entries
  my @all = $self->entries;

  my $index;
  for my $i (0..$#all) {
    if ($all[$i] == $refentry) {
      $index = $i;
      last;
    }
  }

  return $index;
}

=item B<replace>

Replace the entry matching the first argument with the second
argument.

  $msb->replace( $old, $new );

This is used, for exmple, when target information has been finalised.

The entry is I<not> replaced if it happens to have a different
MSBID or Project ID than that of the entry it is replacing.

=cut

sub replace {
  my $self = shift;
  my ($old, $new) = @_;

  # Get the index for the old one
  my $oldind = $self->getindex( $old );

  # Get the msbid and project ID of the new entry
  my $newmsbid = $new->msbid;
  my $newprojectid = $new->projectid;

  # And from this MSB
  my $oldproj = $self->projectid;
  my $oldmsbid = $self->msbid;

  # There is a match if both MSBIDs are undefined
  my $matchmsbid;
  if (defined $newmsbid && defined $oldmsbid) {
    $matchmsbid = 1 if $newmsbid eq $oldmsbid;
  } elsif (!defined $newmsbid && !defined $oldmsbid) {
    $matchmsbid = 1;
  }

  my $matchprojid;
  if (defined $newprojectid && defined $oldproj) {
    $matchprojid = 1 if uc($newprojectid) eq $oldproj;
  } elsif (!defined $newprojectid && !defined $oldproj) {
    $matchprojid = 1;
  }

  if ($matchmsbid && $matchprojid) {
    # The project ID and MSB ID agree with the new entry
    # so we can replace the old entry.
    $self->entries->[$oldind] = $new;

    # And associate that entry with this MSB object
    $new->msb( $self );

    # And update status
    $self->update;
  } else {
    # could not find it
    print "Replacement entry does not match MSBID or Project ID\n";
    print "MSBID: $newmsbid  Current MSBID: ". $self->msbid."\n";
    print "Project: $newprojectid Current : " .$self->projectid."\n";
  }

  return;
}

=item B<cut>

Remove the supplied entry (or entries) from the MSB and
reassign the "end" status to the last entry.

  $msb->cut( @entries );

=cut

sub cut {
  my $self = shift;
  my @cut = @_;

  # Get the entry array reference
  my $all = $self->entries;

  # Get the indices of all the entries that match
  my @indices;
  for my $i (0.. scalar(@$all)-1 ) {
    # We are comparing data references directly not the content
    # since we can have identical ODFs (in terms of content) in
    # multiple places in a single MSB. This does assume that each
    # entry object is unique and not a clone
    # Since there is no == overload that will cause problems
    # we can compare the entries directly
    if (grep { $_ == $all->[$i] } @cut ) {
      # We have a match
      push(@indices, $i);

    }

  }


  # Somewhere to put the entries we have removed so that 
  # we can see if they are contiguous block at the end of the MSB
  my @removed;

  # And make sure it is large enough
  $removed[$#$all] = undef;

  # Now remove those from the array. Starting from the end
  # [else the index that we want to remove will change as earlier
  # entries are removed]
  for (reverse @indices) {
    my $entry = splice(@$all, $_, 1);

    # break the circular reference UNLESS the entry has a status
    # of SENT (in which case we will need to keep track of this
    # association when it has returned). This might cause a memory
    # leak.
    $entry->msb( undef ) unless $entry->status eq 'SENT';

    $removed[$_] = $entry;

  }

  # now make sure the last current entry is tagged as
  # the end of an MSB and the first as the first.
  $self->update;

  # There are two cases we have to watch for here
  # 1. The MSB no longer has any entries on the queue
  # 2. We were observing the MSB and we have just removed
  #    the last entry[ies] on the MSB when one was the current
  #    observation.
  # If the MSB has not been observed at all we need do nothing
  # Simply allow the MSB to be removed. For #1 we should trigger
  # a callback if the MSB hasBeenObserved previously (regardless
  # of where the curindex is set. For #2 we need to know 
  # a) one of the removed entries was the last in the MSB and was
  # associated with the currently selected entry.
  # Note that if we have entries 1,2,3,4,5 and remove 3,4,5 we need
  # to trigger a popup if the highlight is on 3, 4 or 5. Not just 5.

  if ($self->hasBeenObserved) {
    if (!scalar(@$all)) {
      $self->completed;
    } else {
      # Now we need to determine whether we have removed the
      # currently highlighted entry in the queue and all the
      # entries following it.
      if ($self->refentry) {
        my $ref = $self->refentry;

        # Go through the entries that were removed
        # [It would probably be more efficient to do this
        # test in the loop that removes the entries]
        my $refindex;
        for my $i (0..$#removed) {
          next unless defined $removed[$i];
          if ($ref == $removed[$i]) {
            $refindex = $i;
            last;
          }
        }

        # see if we have a match
        if (defined $refindex) {

          my $trigger;          # true if we have completed the MSB
          for my $i ($refindex .. $#removed) {
            # Go through and set trigger on the basis of whether
            # the entry exists in the remaining entries
            if (defined $removed[$i]) {
              $trigger = 1;
            } else {
              $trigger = 0;
            }

          }

          $self->completed if $trigger;

        }

      }

      # The best thing to do maybe to have an hasBeenObserved flag
      # in each entry and then simply say we are done if the
      # last entry in the MSB has been observed.
    }
  }


  return;
}


=back

=begin _PRIVATE_

=head2 Private Methods

=over 4

=item B<_calc_transid>

Calculate the MSB transaction ID and store it in the object.

  $transid = $msb->_calc_transid;

The transaction id consists of the telescope name and the current time.

Nothing happens if a value currently is set (indicating that it was
calculated during entry store).

=cut

sub _calc_transid {
  my $self = shift;
  return if defined $self->transid;

  # Current time
  my ($sec, $musec) = gettimeofday;

  # Telescope of first entry
  my @entries = $self->entries;
  my $tel = $entries[0]->telescope;
  $tel = "NOTEL" unless defined $tel; # should not happen

  # form transaction ID - we are careful to keep the transaction unique.
  # Since we do not know the name of the telescope we can not predict
  # the length of this string so it can not be used in an SDS structure
  # as a key.
  my $tid = sprintf("%s_%d_%06d", $tel, $sec, $musec);
  print "TRANSACTION ID: $tid\n";
  return $self->transid( $tid );
}

=back

=end _PRIVATE_

=head1 NOTES

Note that since an Queue::Entry contains a reference to this MSB
object and that the MSB object contains references to each of its
entries, then this is a circular reference which must be broken before
object destruction can occur.

From the queue viewpoint, clearq is probably the best place to do this.

=head1 AUTHOR

Tim Jenness E<lt>t.jenness@jach.hawaii.eduE<gt>

=head1 COPYRIGHT

Copyright (C) 2002,2004 Particle Physics and Astronomy Research Council.
Copyright (C) 2007 Science and Technology Facilities Council.
All Rights Reserved.

=head1 LICENCE

This program is free software; you can redistribute it and/or modify it
under the terms of the GNU General Public License as published by the
Free Software Foundation; either version 2 of the License, or (at your
option) any later version.

This program is distributed in the hope that it will be useful,but
WITHOUT ANY WARRANTY; without even the implied warranty of MER-
CHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General
Public License for more details.

You should have received a copy of the GNU General Public License along
with this program; if not, write to the Free Software Foundation, Inc.,
59 Temple Place,Suite 330, Boston, MA  02111-1307, USA

=cut


1;
