package Queue::Backend::SCUCD;

=head1 NAME

Queue::Backend::SCUCD - Queue interface to the SCUCD A-task

=head1 SYNOPSIS

  use Queue::Backend::SCUCD;

  $be = new Queue::Backend::SCUCD;
  $be->send_entry($be->qcontents->nextentry)
    if $be->accepting;

=head1 DESCRIPTION

This class can be used to send SCUBA Observation Definition Files
to the SCUBA SCUCD task.

The connection to SCUCD must use DRAMA. This means that an entry is
sent to SCUCD as a DRAMA message and the entry is deemed to have been
completed when that EXECUTE action completes. This means that the
callback for the drama obey, assuming we are running in non-blocking
mode, must set a state variable in the object when the obey has
completed (the C<poll> method will then simply check that variable).

Messages from SCUCD will be intercepted and stored in the object for
retrieval by the C<messages> method.

There are 3 different ways of sending the OBEY:

=over 4

=item 1 Using blocking I/O (MODE=BLOCK)

In this case the the EXECUTE action is sent using an OBEYW. This
means that the C<send_entry> method will not return until the
observation has completed. This will lock the system if
the rest of the system is not aware of DRAMA. (if the system is
already a drama task other DRAMA messages will be serviced although
the Queue will not reflect the fact that a new entry has been sent).
This mode is only really desirable for simple testing.

=item 2 Non-blocking I/O in DRAMA environment (MODE=NONBLOCK)

This is the normal behaviour of the queue. The ODF is sent
using a non-blocking OBEY and returns immediately to the 
queue main loop which will reschedule (querying this class)
until the OBEY completes.

=item 3 Non-blocking I/O without DRAMA Event loop

If the queue is not using an event loop that understand DRAMA
but non-blocking I/O is required, the only option is to fork
a child to do the DRAMA I/O and pass the output and status
back to the parent using a pipe. This is not implemented
at this time.

=back

The mode can be switched using the C<MODE> class method.

Since the messages are sent using DRAMA, assume that we are
always connected to the remote task even if the remote task
is dead (since that will trigger an error anyway). This is
easier than trying to POLL the remote task.

=cut

use 5.006;
use strict;
use warnings;
use Carp;

use base qw/ Queue::Backend /;

use DRAMA;
use Time::Piece qw/ :override /;

=head1 METHODS

=head2 Class Methods

=over 4

=item B<MODE>

Switch between different operating modes. Options are BLOCK and
NONBLOCK (governs whether the ODF is sent to SCUCD using a OBEY
or a OBEYW).

  $mode = Queue::Backend::SCUCD->MODE( "BLOCK" );

Default mode is "NONBLOCK".

=cut

{
  my $MODE = "NONBLOCK";
  sub MODE {
    my $class = shift;
    $MODE = uc(shift) if @_;
    return $MODE;
  }
}

=item B<TASK>

Name of the task to be controlled. Defaults to "SCUCD@SCUVAX" but can be
set to other values for testing.

  $task = Queue::Backend::SCUCD->TASK;

=cut

{
  my $TASK = 'SCUCD@SCUVAX';
  sub TASK {
    my $class = shift;
    $TASK = uc(shift) if @_;
    return $TASK;
  }
}


=back

=head2 Constructor

=over 4

=item B<new>

This is the constructor method. It is identical to the base
constructor except that for the SCUCD, the connection should not be
initiated since it is always assumed to be active (the SCUBA system
must be loaded on the VAX before running the queue) - C<accepting> is
set to true immediately.

  $be = new Queue::Backend::SCUCD;

No arguments are required.

=cut

sub new {
  my $proto = shift;
  my $class = ref($proto) || $proto;

  my $be = $class->SUPER::new;

  # Set accepting to true
  $be->accepting(1);

  return $be;
}

=back

=head2 Accessor methods

=over 4

=item B<accepting>

Indicates that the queue is ready to accept a new C<Queue::Entry>.

  $ok = $be->accepting;

Set to false when SCUBA is actively observing.

=cut

sub accepting {
  my $self = shift;
  $self->{Accepting} = shift if @_;
  return $self->{Accepting};
}

=item B<isconnected>

Indicates whether the object is connected to the backend. Always
returns true for this class since the connection is made
as part of the DRAMA obey.

=cut

sub isconnected {
  return 1;
}

=back

=head2 General methods

=over 4

=item B<_send>

Send the supplied ODF name to the SCUBA task (generally SCUCD).

  $status = $be->_send( $odfname, $entry );

If we are in non-blocking mode, returns immediately, else will
only return when the observation completes (or an error is triggered).

The entry itself is an argument in case it needs to be modified
during callbacks (eg to change its status on completion).

The returned status is a Perl status - true if everything was okay.
False otherwise.

=cut

sub _send {
  my $self = shift;
  my $odfname = shift;
  my $entry = shift;

  my $MODE = $self->MODE;
  my $TASK = $self->TASK;

  # Create argument structure
  my $arg = Arg->Create();
  my $status = new DRAMA::Status;
  $arg->PutString("Argument1", $odfname, $status);

  # change the status of the entry to SENT
  $entry->status("SENT");

  # Create callbacks

  # First the success handler
  my $success = sub { 
    # print "SUCCESS\n";
    $self->_pushmessage( $self->_good,
			 "Observation completed successfully");

    # change status
    $entry->status("OBSERVED");

    # Do post-observation stuff. Includes incrementing the index.
    # Only want to do this if the observations was completed succesfully
    $self->post_obs_tidy($entry);

  };

  my $error   = sub {
    my ($lstat, $msg) = @_;

    # change status to bad
    $entry->status("ERROR");

    # print "ERROR HANDLER: $msg\n";
    $self->_pushmessage( $lstat, "ERROR: $msg" );
  };

  my $complete = sub {
    # The queue must be configured to accept again even if an error was
    # triggered. The assumption is that the queue will be stopped on
    # error anyway but we must be able to accept when the queue restarts.
    $self->accepting(1);
  };

  my $info = sub {
    my $msg = shift;
    print "SCUBA MESSAGE: $msg\n";
    $self->_pushmessage( $self->_good, "SCUCD: $msg");
  };

  # Indicate that we are not accepting at the moment
  $self->accepting(0);


  my $retstatus = 1;
  $self->_pushmessage( $self->_good, "Sending ODF to SCUCD...");
  if ($MODE eq 'NONBLOCK') {

    # do the obey and return immediately but make sure we set
    # up triggers
    # On completion we need to indicate that we are accepting new entries
    # on success we should probably store a message on the stack
    # on error put the message on the stack and error code
    obey $TASK, "OBSERVE", $arg, {
				  -deletearg => 0,
				  -success => $success,
				  -error => $error,
				  -complete => $complete,
				  -info => $info,
				 };



  } else {
    # blocked I/O
    obeyw $TASK, "OBSERVE", $arg, {
				  -success => $success,
				  -error => $error,
				  -info => $info,
				  };

    # Run the completion handler ourselves
    $complete->();
  }

  # Return status is only relevant for the obeyw
  # since the obey will usually return immediately even if the
  # connection is not made. Currently nothing in the obeyw changes
  # this status. Relies on the error handler to trigger a backend
  # error (since this status is meant to be a queue status and not
  # a drama status but we cannot really distinguish between an
  # error connecting to the backend and an error from the backend)
  return $retstatus;

}

=item B<addFailureContext>

Extract information from the queue that may help the caller work
out how to fix the problem associated with the backend failure.

  $be->addFailureContext;

Returns immediately if no C<failure_reason> is stored in the object.

=cut

sub addFailureContext {
  my $self = shift;

  # Get the failure object and the queue contents
  my $r = $self->failure_reason;
  return unless $r;

  # Get the queue contents
  my $q = $self->qcontents;

  # Set the index of the entry
  $r->index( $q->curindex );

  # Add general details from the entry
  $r->details->{ENTRY} = $q->curentry->entity->odf;

  # Get current time
  my $time = gmtime();
  $r->details->{TIME} = $time->datetime;

  # True if we hit an MSB boundary
  my $boundary = 0;

  if ($r->type eq 'MissingTarget') {
    # Need to go through the queue starting at the current index
    # looking for target information OR an indication that we are
    # interested in a calibrator (in which case we stop since we know
    # the list of calibrators)
    my $index = $q->curindex;
    my ($target,$iscal);
    while (defined( my $entry = $q->getentry($index) ) ) {

      # Abort if we hit an MSB boundary on the previous loop
      last if $boundary;

      # If this entry is the end of an MSB flag it for next time
      $boundary = 1 if $entry->lastObs;

      # retrieve the target - presence of a target takes
      # precedence over whether it is a calibrator since
      # if it is a target we *know* the coordinates rather than
      # simply guessing them
      $target = $entry->getTarget;
      last if $target;

      # See if we have a calibrator
      $iscal = $entry->iscal;
      last if $iscal;

      $index++;
    }

    $r->details->{FOLLOWING} = 1 if ($target || $iscal);

    # if we did not find a target or a calibrator
    # reverse the sense of the search and look behind us
    # since it may be that we should be using the same
    # target as the previous observation
    # Do not go above the firstObs of the MSB though
    if (!$target && !$iscal) {
      $boundary = 0;
      $index = $q->curindex - 1;
      while ($index > -1) {
	my $entry = $q->getentry($index);

	# Abort if we hit an MSB boundary on the previous loop
	last if $boundary;

	# If this entry is the start of an MSB flag it for next time
	$boundary = 1 if $entry->firstObs;
		
	# retrieve the target
	$target = $entry->getTarget;
	last if $target;

	# See if we have a calibrator
	$iscal = $entry->iscal;
	last if $iscal;

	$index--;
      }
      $r->details->{FOLLOWING} = 0 if ($target || $iscal);
    }

    # We now either have a valid target or an indication of CAL-ness
    # If we have nothing at all we can not help the observer
    $r->details->{CAL} = 0;
    if ($iscal) {
      print "REQUEST FOR CALIBRATOR\n";
      $r->details->{CAL} = 1;
    } elsif ($target) {
      # get the current az and el
      print "TARGET INFORMATION: ".$target->status ."\n";
      my $un = $target->usenow;
      $target->usenow(0);
      $target->datetime( $time );
      print "EPOCH TIME: ".$target->datetime->epoch() ."\n";
      $r->details->{AZ} = $target->az->radians;
      $r->details->{EL} = $target->el->radians;
      my $name = $target->name;
      $r->details->{REFNAME} = $name if defined $name;
      $target->usenow( $un );
    } else {
      delete $r->details->{FOLLOWING};
    }

  } else {
    croak "Do not understand how to process this Failure object [".
      $r->type."]\n";
  }
}


=back


=head1 SEE ALSO

L<Queue>, L<Queue::Backend>, L<Queue::Entry>, L<Queue::Backend::JACInst>

=head1 AUTHOR

Tim Jenness E<lt>t.jenness@jach.hawaii.eduE<gt>

Copyright 2002-2004 Particle Physics and Astronomy Research Council.
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
