package Queue::Backend;

=head1 NAME

Queue::Backend - interface to the system retrieving queue entries

=head1 SYNOPSIS

  use Queue::Backend;

  $be = new Queue::Backend;
  $be->connectbe;
  $be->disconnect;
  $be->send_entry($be->qcontents->shiftq) if $be->accepting;
  $msg = $be->messages; # Read pending messages
  ($status, $bestatus, $msg) = $be->poll;
  $be->qrunning;


=head1 DESCRIPTION

This class provides an interface to the system retrieving the Queue::Entry
objects when they reach the top of the Queue. Methods are provided for
connecting to the backend, querying whether it is accepting new 
items and for sending new items.

In many cases the Backend can be thought of as something at the
end of an IO object (eg IO::Socket, IO::Pipe). If the IO object
is readable that indicates that there is a message from the Backend.
If the IO object is writable a new Entry may be sent.

It is also possible, that this could be connected to a thread in the
current process. i.e. launch a new thread for each new item, wait until
the thread completes before sending a new item.

=cut

use 5.006;
use warnings;
use strict;
use Carp;

=head1 METHODS

The following methods are provided:

=head2 Constructors

=over 4

=item new

This is the constructor method. If passed a true flag, the connectbe() method
will be invoked so that the backend is connected to the queue. This
is useful in cases where a permananent connection is required. In cases
where the connection is being opened and closed for each send, this
will probably have no effect.

=cut

sub new {
  my $proto = shift;
  my $class = ref($proto) || $proto;

  my $be = {};  # Anon hash
  $be->{Connection} = undef;
  $be->{QRunning} = 0;
  $be->{QContents} = undef;
  $be->{LastSent} = undef;
  $be->{FailReason} = undef;
  $be->{QComplete} = undef;

  bless($be, $class);

  # If required, connect
  $be->connectbe if $_[0];

  return $be;

}

=back

=head2 Accessor Methods

=over 4

=item connection

This returns the object associated with the current connection (if
relevant).

  $connection = $be->connection;

=cut

sub connection {
  my $self = shift;
  $self->{Connection} = shift if @_;
  return $self->{Connection};
}

=item qrunning

This returns the state of the queue. ie. Whether the queue is running
(in which case entries can be sent to the backend) or not. No action
by backend.

  $running = $be->qrunning;
  $be->qrunning(1);

=cut

sub qrunning {
  my $self = shift;
  $self->{QRunning} = shift if @_;
  return $self->{QRunning};
}

=item last_sent

This returns the most recent entry that has been sent to the backend.

  $entry = $be->last_sent;
  $be->last_sent($entry);

Must be a Queue::Entry object (or undef).

=cut

sub last_sent {
  my $self = shift;
  if (@_) {
    my $e = shift;
    if (!defined $e) {
      # If we are not defined - that is okay too
      $self->{LastSent} = undef;
    } elsif (UNIVERSAL::isa($e, 'Queue::Entry')) {
      $self->{LastSent} = $e;
    } else {
      warn "Argument supplied to Queue::Backend::last_sent [$e] is not a Queue::Entry object" if $^W;
    }
  }
  return $self->{LastSent};
}

=item B<failure_reason>

The object describing why the backend has failed. If no reason
is known set to undef.

  $reason = $be->failure_reason();
  $be->failure_reason( $reason );

Argument must be of class C<Queue::Backend::FaulureReason>

=cut

sub failure_reason {
  my $self = shift;
  if (@_) {
    my $e = shift;
    if (!defined $e) {
      # If we are not defined - that is okay too
      $self->{FailReason} = undef;
    } elsif (UNIVERSAL::isa($e, 'Queue::Backend::FailureReason')) {
      $self->{FailReason} = $e;
    } else {
      die "Argument supplied to Queue::Backend::failure_reason [$e] is not a Queue::Backend::FailureReason object";
    }
  }
  return $self->{FailReason};
}

=item qcontents

This contains a reference to the contents of the queue. This is 
required so that the backend can retrieve the next entry from the
queue when it is time to send it. (Rather than popping the next entry
off the queue on the off chance that it can be sent.)

Must be a Queue::Contents object.

=cut

sub qcontents {
  my $self = shift;
  if (@_) {
    my $q = shift;
    if (UNIVERSAL::isa($q, 'Queue::Contents')) {
      $self->{QContents} = $q;
    } else {
      warn "Argument supplied to Queue::Backend::qcontents [$q] is not a Queue::Contents object" if $^W;
    }
  }
  return $self->{QContents};
}

=item qcomplete

This is a callback invoked when the backend realises that the
contents of the queue have been fully observed (usually triggered
when the last entry is completed).

  $handler = $be->qcomplete;
  $be->qcomplete(sub {print "Done"});

Some queue backends do not support this.

=cut

sub qcomplete {
  my $self = shift;
  $self->{QComplete} = shift if @_;
  return $self->{QComplete};
}


=back

=head2 Connections

The following methods are associated with setting up connections
to the backend. In the base class, these do not do a lot.

=over 4

=item connectbe

Make a connection to the backend. This should be sub-classed for
a particular backend.

  $status = $be->connectbe;

Returns true if connection was okay, false if there was an error.
In the base class, does nothing and always returns true.
The connection object is stored in connection().

=cut

sub connectbe {
  my $self = shift;
  $self->connection(1);
  return 1;
}


=item disconnect

Close the connection to the backend. In the base class, this does nothing.

  $status = $be->disconnect;

Returns true if connection was okay, false if there was an error.
In the base class, does nothing and always returns true.
Resets the connection() object.

=cut

sub disconnect {
  my $self = shift;
  $self->connection(undef);
  return 1;
}

=item isconnected

Returns true if we have a connection to the backend, false otherwise.

  $connected = $be->isconnected;

This is not the same as determining whether the backend is waiting
for the next queue entry (see accepting() method)

=cut

sub isconnected {
  my $self = shift;

  # Check to see if we have a connection object
  my $con = $self->connection;

  my $iscon = (defined $con ? 1 : 0);
  return $iscon;
}

=back

=head2 Sending entries

These methods are used to send entries to the backend and enquire
the current status.

=over 4

=item accepting

Indicates whether the backend is ready to accept a new Queue::Entry.

  $ok = $be->accepting;

For the base class, returns true if isconnected().

=cut

sub accepting {
  my $self = shift;
  return $self->isconnected;
}

=item send_entry

Send a Queue::Entry to the backend. Uses the prepare()/be_object() 
methods of Queue::Entry to retrieve the thing that should be sent
to the backend. Uses the queue stored in qcontents().
This object is queried for the next entry if an entry
can be sent.

  $status = $be->send_entry() if $be->qrunning;

Returns a status. This method does not return anything from the 
backend itself. Use the poll() method to actually do that.

The method return status can be:

   0 - bad status
   1 - successful send or 
       queue is stopped or we are not accepting

The base class must supply the method that actually does the sending
(C<_send>).

=cut

sub send_entry {
  my $self = shift;
  croak 'Usage: send_entry()' if @_;

  # Read the queue contents
  my $q = $self->qcontents;

  # check that the queue is running (otherwise we cant send)
  return 1 unless $self->qrunning;

  # In order that we dont make a spurious connection to the backend
  # if there are no entries on the queue, we now check the Queue
  # to make sure it contains something
  # If the queue is accepting we make sure that last_sent is cleared.
  # (since we didnt send something even though the backend is accepting)
  unless ($#{$q->contents} > -1) {
    $self->last_sent(undef) if $self->accepting;
    return 1;
  }

  # If the queue is accepting entries
  # Note that the backend could be accepting entries but not be
  # connected, or vice versa....
  # Need to check both conditions.

  # Check for a connection - make one if necessary
  $self->connectbe() unless $self->isconnected();

  # Now make sure we are accepting
  # Return 1 if not accepting
  return 1 unless $self->accepting;

  # Now we can retrieve the next entry off the queue
  my $entry = $q->get_for_observation;

  # Return if there was no entry
  return 1 unless defined $entry;

  # Prepare for transmission
  my $pstat = $entry->prepare;

  # if we got a reason object back then we failed
  # so store it, augment it  and set bad status.
  if ($pstat) {
    $self->failure_reason($pstat);
    $self->addFailureContext();
    return 0;
  }

  # Get the thing that is to be sent
  my $entity = $entry->be_object;

  # Now send to this to the backend (along with the entry)
  my $status = $self->_send($entity, $entry);

  # note that $entity is probably destroyed immediately after
  # we exit this routine. This will cause problems if an Entry
  # destructor has been implemented (eg deleting files).
  # We should keep hold of the entry until at least
  # the next poll(). Store it in the last_sent field
  # It will be overwritten when the next thing is sent but that
  # will be okay in general -- it lets us keep a record of what
  # is currently with the backend
  $self->last_sent($entry);


  # Return the values
  return $status;
}


=item poll

Polls the backend to decide whether a new entry should be sent
or a message is waiting for us that should be retrieved.
If necessary, this method will send the next entry and will return
any messages.

  ($status, $bestatus, $messages) = $be->poll;

Returns a method status (see eg send_entry()), a status from
the backend and any messages from the backend. The last two
may be undef. Status is good if true, bad if false.

This method provides the primary way of interacting
with the requested backend.

=cut

sub poll {
  my $self = shift;

  # Assume everything okay to start with
  my $status = 1;

  # Check for messages (if we are connected) before and after
  # sending entries. Need to do this because weith asyncronous
  # callbacks it is possible that an error has occurred between
  # polls.
  my ($bestatus, $msg) = $self->messages if $self->isconnected;

  # Return if we are already in trouble
  return ($status, $bestatus, $msg)
    if $bestatus;

  # Try to send an entry if the queue is running.
  # this will do nothing if the queue is not accepting
  if ($self->qrunning) {
    $status = $self->send_entry();
    #print "##### STATUS FROM send_entry: $status\n";
  } else {
    # If the backend is accepting but the queue is not running
    # set last sent to undef
    $self->last_sent(undef) if $self->accepting;
  }


  # Check for messages (if we are connected)
  ($bestatus, $msg) = $self->messages if $self->isconnected;

  #print "QStatus: $status, SCUCD status: $bestatus ";
  #print "QRunning: ". $self->qrunning . " Accepting: ". $self->accepting;
  #print " Index: " . $self->qcontents->curindex;
  #print   "\n";

  return ($status, $bestatus, $msg);
}


=item B<post_obs_tidy>

Runs code that should occur after the observation has been completed
but before the next observation is requested.

In the base class this does nothing. For SCUCD this will cause the
index to be incremented.

=cut

sub post_obs_tidy {
  my $self = shift;
  return;
}

=item B<addFailureContext>

Extract information from the queue that may help the caller work
out how to fix the problem associated with the backend failure.

  $be->addFailureContext;

No effect in base class.


=cut

sub addFailureContext {
  return;
}


=item messages

Retrieves pending messages from the backend.
Any status values from the backend are returned
along with any pending messages. undef is used if we are not
connected or there are no pending messages.

  ($bestatus, $msg) = $be->messages;

The base class returns a backend status of 0 and a message
containing the current time (UT).

=cut

sub messages {
  my $self = shift;
  my $msg = undef;

  $msg = gmtime if $self->isconnected;

  return (0, $msg);
}


=item _send

Low-level method to actually send information to the backend.
This requires knowledge of the type of object stored in
connection(). Argument is the actual thing that is passed to
the backend. Returns a status.

  $status = $be->_send("hello", $entry);

The base class simply prints data to stdout.

The entry itself is an argument in case it needs to be modified
during callbacks (eg to change its status on completion).

=cut

sub _send {
  my $self = shift;
  croak 'Usage: Queue::Backend->_send(data)'
    unless scalar(@_) == 1;

  my $data = shift;

  print STDOUT "Sending: $data\n";

  return 1;
}

=back

=cut




1;

=head1 SEE ALSO

L<Queue>, L<Queue::Contents>

=head1 AUTHOR

Tim Jenness E<lt>t.jenness@jach.hawaii.eduE<gt>

Copyright (C) 1999-2002 Particle Physics and Astronomy Research Council.
All Rights Reserved.

=cut

