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

  $status = $be->_send( $odfname );

If we are in non-blocking mode, returns immediately, else will
only return when the observation completes (or an error is triggered).

=cut

sub _send {
  my $self = shift;
  my $odfname = shift;

  my $MODE = $self->MODE;
  my $TASK = $self->TASK;

  # Create argument structure
  my $arg = Arg->Create();
  my $status = new DRAMA::Status;
  $arg->PutString("Argument1", $odfname, $status);

  DRAMA::MsgOut( $status, "INFO: ArgID: " . ${$arg->id} );

  # Create callbacks
  # - There seems to be a bug in the DRAMA/perl interface. If
  # I do not store a reference to the argument structure in one of the
  # callbacks (to stop it being destroyed) I get a SDS-E-BADID error
  # from Uface handler. This may well generate a descriptor leak.
  my $success = sub { 
    print "SUCCESS\n";
    $self->_pushmessage( 0, "CLIENT: Observation completed successfully");
    $self->accepting(1);
    $arg; # keep alive
  };

  my $error   = sub {
    my ($lstat, $msg) = @_;
    print "ERROR HANDLER: $msg\n";
    $self->_pushmessage( $lstat, "ERROR: $msg" );
  };

  my $complete = sub {
    print "COMPLETE\n";
#    Dits::PutRequest(Dits::REQ_EXIT,$status);
    $self->post_obs_tidy;
  };

  my $info = sub {
    my $msg = shift;
    print "MESSAGE: $msg\n";
    $self->_pushmessage( 0, "REMOTE: $msg");
  };

  # Indicate that we are not accepting at the moment
  $self->accepting(0);


  my $retstatus = 0;
  if ($MODE eq 'NONBLOCK') {

    # do the obey and return immediately but make sure we set
    # up triggers
    # On completion we need to indicate that we are accepting new entries
    # on success we should probably store a message on the stack
    # on error put the message on the stack and error code
    obey $TASK, "OBSERVE", $arg, {
				  -success => $success,
				  -complete => $complete,
				  -error => $error,
				  -info => $info,
				 };

  } else {
    # blocked I/O
    obeyw $TASK, "OBSERVE", $arg, {
				  -success => $success,
				  -complete => $complete,
				  -error => $error,
				  -info => $info,
				  };


  }

  # Return status is only relevant for the obeyw
  # since the obey will usually return immediately even if the
  # connection is not made
  return $retstatus;

}

=item B<post_obs_tidy>

Runs code that should occur after the observation has been completed
but before the next observation is requested.

Increments the current index position by one to indicate that the next
observation should be selected. If the index is not incremented (no
more observations remanining) the queue is stopped and the index is
reset to the start.

=cut

sub post_obs_tidy {
  my $self = shift;
  my $status = $self->contents->incindex;
  if (!$status) {
    $self->qrunning(0);
    $self->contents->curindex(0);
  }
  return;
}

=item B<messages>

Retrieves messages (one at a time) that have been cached by the
DRAMA interaction.

 ($msgstatus, $mdf) = $be->messages;

Empty list is returned if we have no pending messages.

Note that messages can be present even if the queue is accepting
again. Care must be taken that the method reading these messages clears
the message stack before assuming further action can be taken.

=cut

sub messages {
  my $self = shift;
  my ($status, $msg) = $self->_shiftmessage;

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
