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

# Init the drama system
# Not required if we are already running drama
# (so will be a no-op)
# named QUEDOER for historical reasons
#DPerlInit( "QUEDOER" );

=head2 METHODS

=head1 Class Methods

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
    $self->_pushmessage( 0, "Observation completed successfully");

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
    $self->_pushmessage( 0, "SCUCD: $msg");
    use Data::Dumper;
  };

  # Indicate that we are not accepting at the moment
  $self->accepting(0);


  my $retstatus = 1;
  $self->_pushmessage( 0, "Sending ODF to SCUCD...");
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

=item B<post_obs_tidy>

Runs code that should occur after the observation has been completed
but before the next observation is requested. The argument is the
entry object that was sent.

  $be->post_obs_tidy( $curentry );

Increments the current index position by one to indicate that the next
observation should be selected. If the index is not incremented (no
more observations remanining) the queue is stopped and the index is
reset to the start.

Additionally, the MSB should be marked as complete at this point.
This will require additional status flags to make sure that
the observer is prompted if the queue is reloaded without the MSB
having been completed.

If a completion handler has been registered with the object (using
method qcomplete()) it will be invoked with argument of the last entry
when the last observation has been completed. Queue completion handler
will not trigger if the queue has been reloaded.

If a completion handler has been registered with the entry to trigger
when an MSB has been completely observed (using the method
msbcomplete()) it will be called with that entry. This callback
triggers even if the queue has been modified in the mean time because
the entry knows that it was the last entry in the MSB.

If the index in the queue has been modified between sending this
entry and it completing, the index will not be incremented.

Does not yet trap to see whether the actual queue was reloaded.

=cut

sub post_obs_tidy {
  my $self = shift;
  my $entry = shift;
  my $status;

  # Indicate that an entry in the MSB has been observed
  if ($entry->msb) {
    $entry->msb->hasBeenObserved( 1 );
  }

  # if the index has changed we are in trouble
  # so dont do any tidy. if lastindex is not defined that means
  # we have reloaded the queue and so should not do any tidy up
  if (defined $self->qcontents->lastindex &&
     $self->qcontents->lastindex == $self->qcontents->curindex) {
    print "LASTINDEX was defined and was equal to curindex\n";
    $status = $self->qcontents->incindex;
    if (!$status) {
      # The associated parameters must be updated independently since
      # we do not have access to the DRAMA parameters from here
      $self->qrunning(0);
      $self->qcontents->curindex(0);
      $self->_pushmessage( 0, "No more entries to process. Queue is stopped");

      # trigger when the queue hits the end
      if ($entry && $self->qcomplete) {
	$self->qcomplete->($entry);
      }

    }
  } else {
    print "LASTINDEX did not match so we do not change curindex\n";
  }

  # clear the lastindex field since we have done it now
  $self->qcontents->lastindex(undef);

  # call handler if we have one and if this is the last observation
  # in the MSB
  if ($entry && $entry->lastObs && $self->msbcomplete) {
    $self->msbcomplete->($entry);
  }

  return;
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

  if ($r->type eq 'MissingTarget') {
    # Need to go through the queue starting at the current index
    # looking for target information OR an indication that we are
    # interested in a calibrator (in which case we stop since we know
    # the list of calibrators)
    my $index = $q->curindex;
    my ($target,$iscal);
    while (defined( my $entry = $q->getentry($index) ) ) {

      # retrieve the target - presence of a target takes
      # precedence over whether it is a calibrator since
      # if it is a target we *know* the coordinates rather than
      # simply guessing them
      $target = $entry->getTarget;
      last if $target;

      # See if we have a calibrator
      $iscal = $entry->entity->iscal;
      last if $iscal;

      $index++;
    }

    $r->details->{FOLLOWING} = 1;

    # if we did not find a target or a calibrator
    # reverse the sense of the search and look behind us
    # since it may be that we should be using the same
    # target as the previous observation
    if (!$target && !$iscal) {
      $index = $q->curindex - 1;
      while ($index > -1) {
	my $entry = $q->getentry($index);
		
	# retrieve the target
	$target = $entry->getTarget;
	last if $target;

	# See if we have a calibrator
	$iscal = $entry->entity->iscal;
	last if $iscal;

	$index--;
      }
      $r->details->{FOLLOWING} = 0;
    }

    # We now either have a valid target or an indication of calness
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
      $r->details->{AZ} = $target->az;
      $r->details->{EL} = $target->el;
      $target->usenow( $un );
    } else {
      delete $r->details->{FOLLOWING};
    }

  } else {
    croak "Do not understand how to process this Failure object [".
      $r->type."]\n";
  }
}


=item B<messages>

Retrieves messages (one at a time) that have been cached by the
DRAMA interaction.

 ($msgstatus, $msg) = $be->messages;

Empty list is returned if we have no pending messages.

Note that messages can be present even if the queue is accepting
again. Care must be taken that the method reading these messages clears
the message stack before assuming further action can be taken.

=cut

sub messages {
  my $self = shift;
#  my ($status, $msg) = $self->_shiftmessage;

  # clear all the messages but keep non-zero status
  my ($status, $msg);
  my @msgs;
  $status = 0;
  while (@msgs = $self->_shiftmessage) {
    $status = $msgs[0] if $msgs[0] != 0;
    $msg .= $msgs[1] . "\n";
  }


  if (defined $msg) {
    return ($status, $msg);
  } else {
    return ();
  }
}

=back

=begin __PRIVATE_METHODS__

=head2 Private Methods

=item B<_pending>

Array of arrays containing messages (and associated status) that have
been recieved from the remote task and that are waiting to be read by
the C<messages> method.

The first element in each array is the status, the second element
is the actual message. "0" indicates good status.

=cut

sub _pending {
  my $self = shift;
  # initialize first time in
  $self->{PendingMessages} = [] unless $self->{PendingMessages};

  # read arguments
  @{$self->{PendingMessages}} = @_ if @_;

  # Return ref in scalar context
  if (wantarray) {
    return @{$self->{PendingMessages}};
  } else {
    return $self->{PendingMessages};
  }

}

=item B<_pushmessage>

Push message (and status) onto pending stack.

  $self->_pushmessage( $status, $message );

=cut

sub _pushmessage {
  my $self = shift;
  push(@{$self->_pending}, [ @_ ]);
}

=item B<_shiftmessage>

Shift oldest message off the pending stack.

  ($status, $message) = $self->_shiftmessage;

=cut

sub _shiftmessage {
  my $self = shift;
  my $arr = shift(@{$self->_pending});
  if (defined $arr) {
    return @$arr;
  } else {
    return ();
  }

}

=back

=end __PRIVATE_METHODS__

=head1 SEE ALSO

L<Queue>, L<Queue::Backend>, L<Queue::Entry>

=head1 AUTHOR

Tim Jenness E<lt>t.jenness@jach.hawaii.eduE<gt>
Copyright 2002 Particle Physics and Astronomy Research Council.
All Rights Reserved.

=cut


1;
