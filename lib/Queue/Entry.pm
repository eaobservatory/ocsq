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

=head2 Constructors

=over 4

=item new

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

=item entity

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



=item label

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

=item status

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

=item be_object

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

=item configure

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

=item prepare

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

=item projectid

Returns the project ID associated with this entry.

  $proj = $entry->projectid;

The base class always returns undef.

=cut

sub projectid {
  my $self = shift;
  return ();
}

=item msbid

Returns the MSB ID associated with this entry.

  $msbid = $entry->msbid;

The base class always returns undef.

=cut

sub msbid {
  my $self = shift;
  return ();
}

=back

=head2 Display methods

These methods convert the object to something that can be displayed.

=over 4

=item string

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

Estimated time required for the entry to execute.

  $duration = $e->duration();

Returns a C<Time::Seconds> object. Base class reeturns 0.

=cut

sub duration {
  my $self = shift;
  return Time::Seconds->new(0);
}

=back

=head2 Destructors

Object destructors may be supplied to tidy up any temporary files
generated by the prepare() method. No destructor is defined in the
base class.

=cut

1;

=head1 SEE ALSO

L<Queue>, L<Queue::Contents>

=head1 AUTHOR

Tim Jenness (t.jenness@jach.hawaii.edu)
(C) Copyright PPARC 1999.

=cut
