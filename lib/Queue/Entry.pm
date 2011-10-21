package Queue::Entry;

=head1 NAME

Queue::Entry - Class describing a Queue entry

=head1 SYNOPSIS

  use Queue::Entry;

  $entry = new Queue::Entry($thing);

  $entry->label($label);
  $entry->configure($thing);
  $text = $entry->string;
  $entry->prepare;

=head1 DESCRIPTION

This class describes Entries objects that can be manipulated in
a Queue::Contents class.

=cut

use strict;
use Carp;
use Time::Seconds;

=head1 METHODS

The following methods are provided:

=head2 Class Methods

The following class methods are provided:

=over 4

=item B<outputdir>

Directory to which all queue entries should be sent during the C<prepare>
phase. This is a class method since it assumes that all entries will
write their files to the same location regardless of the instrument. This
may be a bad assumption (in which case the method will have to be subclassed).

  Queue::Entry->outputdir( "/tmp" );
  my $outdir = $entry->outputdir();

Can be used to set or retrieve the directory location. Default location
is C</tmp>.

=cut

{
  my $OUTPUTDIR;
  sub outputdir {
    my $self = shift;
    if (@_) {
      $OUTPUTDIR = shift;
    }
    return $OUTPUTDIR;
  }
}

=back

=head2 Constructors

=over 4

=item B<new>

This is the Contents constructor. Any arguments are passed to the
configure() method.

  $entry = new Queue::Entry;

=cut

sub new {
  my $proto = shift;
  my $class = ref($proto) || $proto;

  my $frame = {};  # Anon hash
  $frame->{Entity} = undef;
  $frame->{Label}  = undef;
  $frame->{BE}     = undef;
  $frame->{Duration} = undef;
  $frame->{Status} = "QUEUED";
  $frame->{MSB}    = undef;
  $frame->{QID}    = undef;

  bless($frame, $class);

  $frame->configure(@_) if @_;

  return $frame;
}


=back

=head2 Accessor Methods

=over 4

=item B<entity>

Sets or returns the actual entity associated with the Entry in the 
Queue. This could be as simple as a file name or something more complex
such as a perl data structure or object - this depends on the details
of the class.

  $entity = $entry->entity;
  $entry->entity($entity);

=cut


sub entity {
  my $self = shift;
  $self->{Entity} = shift() if @_;
  return $self->{Entity};
}



=item B<label>

Sets or returns the label associated with this entry. This is not
necessarily the same thing as returned by the string() method.
(Although it could be).

  $lab = $entry->label;
  $entry->label($lab);

=cut

sub label {
  my $self = shift;
  $self->{Label} = shift() if @_;
  return $self->{Label};
}

=item B<instrument>

String describing the instrument associated with this queue entry.
Usually a constant hard-wired into each subclass.

  $inst = $e->instrument();

This string is normally meant to match that used in the instrument
attribute used for queue entry XML.

=cut

sub instrument {
  return "BASECLASS";
}

=item B<telescope>

String describing the telescope associated with this queue entry.
This is simply used for sanity checking the Queue Entry XML and in most
cases returns a constant value.

 $tel = $e->telescope();

=cut

sub telescope {
  return "BASECLASS";
}

=item B<status>

Sets or returns the status associated with this entry. Current 
recognized values are:

  QUEUED  - entry default state
  SENT    - has been sent to the backend
  OBSERVED- has been observed successfully
  ERROR   - has been observed with error

These values are currently free format and no attempt is made
to verify that we know what they mean.

  $status = $entry->status();
  $entry->status('SENT');

The status is also returned when the object is stringified. This
can be used to color code the results.

=cut

sub status {
  my $self = shift;
  $self->{Status} = shift() if @_;
  return $self->{Status};
}

=item B<msb>

C<Queue::MSB> object associated with this entry. If this is undefined,
indicates that the entry is not associated with an MSB.

  $msb = $e->msb;

=cut

sub msb {
  my $self = shift;
  if (@_) {
    $self->{MSB} = shift;
  }
  return $self->{MSB};
}

=item B<queueid>

A tag that is used to track this particular entry, or its associated
MSB, in the queue system. If an MSB is associated with this entry, the
queue ID of the MSB will always be returned (to allow the MSB to be
referenced by queue users). If no MSB is associated with this entry,
or no queue ID can be retrieved from the MSB, then this can be treated
as a normal accessor method.

  $qid = $e->queueid;
  $e->queueid( $qid );

=cut

sub queueid {
  my $self = shift;
  if (@_) {
    $self->{QID} = shift;
  }

  # Now look for an MSB
  my $msb = $self->msb;
  if ($msb && defined $msb->queueid) {
    return $msb->queueid;
  } else {
    return $self->{QID};
  }

}

=item B<lastObs>

This entry is associated with the last observation in an MSB.
The state is set by the queue on upload. If an observation
is the last observation in an MSB then special triggers may be
invoked.

  $e->lastObs(1);
  $islast = $e->lastObs;

=cut

sub lastObs {
  my $self = shift;
  if (@_) {
    $self->{lastObs} = shift;
  }
  return $self->{lastObs};
}

=item B<firstObs>

This entry is associated with the first observation in an MSB.
The state is set by the queue on upload.

  $e->firstObs(1);
  $isfirst = $e->firstObs;

=cut

sub firstObs {
  my $self = shift;
  if (@_) {
    $self->{firstObs} = shift;
  }
  return $self->{firstObs};
}

=item B<be_object>

This contains the information that is to be sent to the Queue
backend. For example, this may be a filename, a FreezeThaw string 
(see L<FreezeThaw> or L<Storable>) or even an SDS object. It is usually set by 
the prepare() method.

=cut

sub be_object {
  my $self = shift;
  $self->{BE} = shift() if @_;
  return $self->{BE};
}


=back

=head2 Configuration

These methods control object configuration.

=over 4

=item B<configure>

Configure the class. Accepts 2 arguments, the entry label and
the thing that is actually important for the entry. If only
one argument is supplied, both label() and entity() are set to this
value.

  $entry->configure('label', $item);
  $entry->configure('label');

This method is automatically called by the new() constructor
if arguments are supplied to new().

No values are returned.

=cut

sub configure {
  my $self = shift;
  croak 'Usage: configure(label,[entity])' if scalar(@_) < 1;

  my $label = shift;
  $self->label($label);

  my $entity;
  if (@_) {
    $entity = shift;
  } else {
    $entity = $label;
  }
  $self->entity($entity);

}

=item B<write_entry>

Write the entry to disk. Usually called in conjunction with the
prepare() method. The base class does not implement a routine.

=cut

sub write_entry {
  croak "Must subclass write_entry";
}

=item B<prepare>

This method prepares the Entry item for sending to a backend.  For the
base class this stores the label() in be_object().  Sub-classes may
use this opportunity to, for example, write the thing stored in
entity() to a disk and store the filename in be_object().

This should be called just before sending the entry to the backend.
Note that this does require that the Entry class has to know what the
Backend class is expecting to send to the Queue backend. For example,
using ODFs will probably only work with a TODD backend.

Returns undef if everything worked okay. Returns a
C<Queue::Backend::FailureReason> object if there was a problem that
could not be fixed.

=cut

sub prepare {
  my $self = shift;
  $self->be_object($self->label);
  return;
}

=item B<getTarget>

Retrieve any target information associated with the entry. Returns
C<undef> if no target is specified else returns an C<Astro::Coords> object.

  $coords = $e->getTarget;

=cut

sub getTarget {
  my $self = shift;
  return undef;
}

=item B<targetIsCurrentAz>

Returns true if the target corresponds to the current location of the telescope
rather than a particular coordinate.

 $iscur = $e->targetIsCurrentAz;

=cut

sub targetIsCurrentAz {
  return 0;
}

=item B<targetIsFollowingAz>

Returns true if the target corresponds to an entry referring to the coordinates
of a following entry.

 $iscur = $e->targetIsFollowingAz;

=cut

sub targetIsFollowingAz {
  return 0;
}


=item B<setTarget>

Set target information associated with the entry. Requires an C<Astro::Coords>
object.

  $e->setTarget( $coords );

=cut

sub setTarget {
  my $self = shift;
  return undef;
}

=item B<clearTarget>

Clear target information associated with the entry.

  $e->clearTarget();

=cut

sub clearTarget {
  my $self = shift;
  return undef;
}

=item B<iscal>

Returns true if the entry seems to be associated with a
science calibration observation (e.g. a flux or wavelength
calibration). Returns false otherwise.

  $iscal = $seq->iscal();

The base class returns false unless the entity referenced by
the entry implements this method.

=cut

sub iscal {
  my $self = shift;
  my $entity = $self->entity;
  if (defined $entity && $entity->can("iscal")) {
    return $entity->iscal;
  } else {
    warn "iscal is not implemented. Assuming false.";
    return 0;
  }
}

=item B<isMissingTarget>

Indicates the entry should have a target but does not have
one set.

 $ismiss = $e->isMissingTarget;

=cut

sub isMissingTarget {
  my $self = shift;
  my $entity = $self->entity;
  if (defined $entity && $entity->can("isMissingTarget")) {
    return $entity->isMissingTarget;
  } else {
    warn "isMissingTarget is not implemented. Assuming false.";
    return 0;
  }
}

=item B<isGenericCal>

Returns true if the entry seems to be associated with a
generic calibration observation such as array tests or noise
measurements.

 $isgencal = $e->isGenericCal();

In some cases it is possible for a single entry to refer to
a generic calibration and a science observation.

The base class returns false unless the entity referenced by
the entry implements this method.

=cut

sub isGenericCal {
  my $self = shift;
  my $entity = $self->entity;
  if (defined $entity && $entity->can("isGenericCal")) {
    return $entity->isGenericCal;
  } else {
    warn "isGenericCal is not implemented. Assuming false.";
    return 0;
  }
}

=item B<isScienceObs>

Return true if this entry includes a science observation.

 $issci = $e->isScienceObs;

The base class returns true unless the entity referenced by
the entry implements this method.

=cut

sub isScienceObs {
  my $self = shift;
  my $entity = $self->entity;
  if (defined $entity && $entity->can("isScienceObs")) {
    return $entity->isScienceObs;
  } else {
    warn "isScienceObs is not implemented. Assuming true.";
    return 1;
  }
}


=item B<projectid>

Returns the project ID associated with this entry.

  $proj = $entry->projectid;

The base class always returns undef.

=cut

sub projectid {
  my $self = shift;
  return ();
}

=item B<msbid>

Returns the MSB ID associated with this entry.

  $msbid = $entry->msbid;

The base class always returns undef.

=cut

sub msbid {
  my $self = shift;
  return ();
}

=item B<msbtid>

MSB transaction ID. Undefined if the entry does not refer to a Queue::MSB
object.

 $msbtid = $entry->msbtid;

If an argument is supplied, the transaction ID can be set, but only
if the entry is part of an MSB.

=cut

sub msbtid {
  my $self = shift;
  my $msb = $self->msb;
  if (defined $msb && defined $self->entity && $self->entity->can("msbtid")) {
    if (@_) {
      $self->entity->msbtid( $_[0] );
    } else {
      return $self->entity->msbtid();
    }
  }
  return;
}

=back

=head2 Display methods

These methods convert the object to something that can be displayed.

=over 4

=item B<string>

Returns a string representation of the object. The base class simply
returns the output from the label() method.

  $string = $entry->string;

There are no arguments. Includes the status.

=cut

sub string {
  my $self = shift;
  my $posn = $self->msb_status;
  my $project = $self->projectid;
  $project = "NONE" unless defined $project;
  $project = substr($project, 0, 10);
  return sprintf("%-10s%-10s%-14s%s",$self->status,
		 $project,$self->msb_status,$self->label);
}

=item B<msb_status>

Return a string summary of the lastObs, firstObs and 
whether we are part of an MSB.

  $stat = $e->msb_status;

Includes the queue id if defined.

=cut

sub msb_status {
  my $self = shift;
  my $string;
  if ($self->msb) {
    # Include the Queue ID. If we do not have one simply use the
    # string "MSB"
    my $qid = $self->queueid;
    if (defined $qid) {
      $qid = sprintf( "%03d", $qid);
    } else {
      $qid = "MSB";
    }
    $string = $qid;
    if ($self->firstObs && $self->lastObs) {
      $string .= " Start&End";
    } elsif ($self->firstObs) {
      $string .= " Start";
    } elsif ($self->lastObs) {
      $string .= " End";
    }
  } else {
    $string = "CAL";
  }
  return $string;

}

=item B<duration>

Estimated time required for the entry to execute. An explicit value
can be stored if known (e.g. supplied by the translator but not part
of the low-level "sequence" or configuration information). A value
can be stored as either a plain integer or a Time::Seconds object.

  $e->duration( 5400 );
  $duration = $e->duration();

Returns a C<Time::Seconds> object.

On fetch, if no value is stored in the object, the duration method
is called in the entity object (if present). That value is not
stored in the object though so each subsequent call will force a
recalculation unless the value is explicitly stored.

Returns 0 seconds if the entity object is either not present or does
not support a C<duration> method.

=cut

sub duration {
  my $self = shift;
  if (@_) {
    my $t = shift;
    if (UNIVERSAL::isa($t, "Time::Seconds")) {
      $self->{Duration} = $t;
    } else {
      $self->{Duration} = Time::Seconds->new( int($t) );
    }
  }
  # Need to return a value
  if (defined $self->{Duration}) {
    # we have a value cached so return it
    return $self->{Duration};
  } else {
    my $entity = $self->entity;
    # if we have an entity that implements "duration" call it
    if (defined $entity && $entity->can("duration")) {
      return $entity->duration;
    }
  }
  # else return 0 seconds
  return Time::Seconds->new(0);
}

=back

=head2 Destructors

Object destructors may be supplied to tidy up any temporary files
generated by the prepare() method. No destructor is defined in the
base class.

=head1 SEE ALSO

L<Queue>, L<Queue::Contents>, L<Queue::Entry>, L<Queue::EntryXMLIO>.

=head1 AUTHOR

Tim Jenness E<lt>t.jenness@jach.hawaii.eduE<gt>

Copyright (C) 1999-2004 Particle Physics and Astronomy Research Council.
All Rights Reserved.

This program is free software; you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation; either version 2 of the License, or (at your option) any later
version.

This program is distributed in the hope that it will be useful,but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with
this program; if not, write to the Free Software Foundation, Inc., 59 Temple
Place,Suite 330, Boston, MA  02111-1307, USA

=cut

1;
