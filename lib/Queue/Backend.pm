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

use constant GOOD_STATUS => 0;

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
  $be->{MSBComplete} = undef;

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

Some queue backends do not support this. This is distinct from
and MSB completion (see msbcomplete()) which can be triggered even
when more observations are on the queue.

=cut

sub qcomplete {
  my $self = shift;
  $self->{QComplete} = shift if @_;
  return $self->{QComplete};
}

=item msbcomplete

This is a callback invoked when the backend realises that the
the current MSB has been fully observed (usually triggered
when the last MSB entry is completed).

  $handler = $be->msbcomplete;
  $be->msbcomplete(sub {print "Done"});

Some queue backends do not support this.

=cut

sub msbcomplete {
  my $self = shift;
  $self->{MSBComplete} = shift if @_;
  return $self->{MSBComplete};
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
    $entry = $self->addFailureContext();
    if (defined $entry) {
      # we were returned a modified entry based on the failure
      # condition. Clear the failure and try one more time.
      $self->failure_reason(undef);
      $pstat = $entry->prepare;
      if ($pstat) {
        # Check out new failure reason but do not trap for a
        # modified entry second time round
        $self->failure_reason($pstat);
        $entry = $self->addFailureContext();
        return 0;
      }
    } else {
      # have to say we failed
      return 0;
    }
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
  # sending entries. Need to do this because with asyncronous
  # callbacks it is possible that an error has occurred between
  # polls.
  my ($bestatus, $msg);
  ($bestatus, $msg) = $self->messages if $self->isconnected;

  # Go through the bestatus values to see if we are in trouble
  my $trouble = 0;
  if (defined $bestatus) {
    for (@$bestatus) {
      if ($_ != $self->_good) {
	$trouble = 1;
	last;
      }
    }
  }

  # Return if we are already in trouble
  # Note that if there are no messages we get undef which actually
  # maps to false [or good status in this case] but we should
  # be explicit about it
  return ($status, $bestatus, $msg) if $trouble;

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


  # Check for messages (if we are connected) and append these
  # messages to the one we read earlier
  my @new;
  @new = $self->messages if $self->isconnected;

  # if there are some messages assign backend status and append
  # the information
  if (@new) {
    $bestatus = [] unless defined $bestatus;
    $msg = [] unless defined $msg;
    push(@$bestatus, @{ $new[0] });
    push(@$msg, @{ $new[1]});
  } elsif (!defined $bestatus) {
    # Need to specify a good status and empty message
    # if nothing was pending
    $bestatus = [ $self->_good ];
    $msg = [];
  }

  #print "QStatus: $status, SCUCD status: $bestatus ";
  #print "QRunning: ". $self->qrunning . " Accepting: ". $self->accepting;
  #print " Index: " . $self->qcontents->curindex;
  #print   "\n";

  return ($status, $bestatus, $msg);
}


=item B<post_obs_tidy>

Runs code that should occur after the observation has been completed
successfully but before the next observation is requested. The
argument is the entry object that was sent to the backend.

  $be->post_obs_tidy( $curenty );

Increments the current index position by one to indicate that the next
observation should be selected. If the index is not incremented (no
more observations remaining) the queue is stopped and the index is
reset to the start.

Additionally, the MSB associated with the entry is marked to indicate
that a part of the MSB has been observed (see L<OMP::MSB/"hasBeenObserved">).

If a completion handler has been registered with the object (using
method qcomplete()) it will be invoked with argument of the last entry
when the last observation in the queue has been completed. Queue
completion handler will not trigger if the queue has been reloaded.

If a completion handler has been registered with the entry to trigger
when an MSB has been completely observed (using the method
C<msbcomplete()>) it will be called with that entry. This callback
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
  my $prevstat;
  if ($entry->msb) {
    # Get the previous status of the MSB so that we can
    # work out whether we are the last chance to complete this MSB.
    $prevstat = $entry->msb->hasBeenObserved();

    # Indicate that the msb has now been observed
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
      $self->_pushmessage( $self->_good,
			   "No more entries to process. Queue is stopped.");

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
    $entry->msb->hasBeenCompleted(1) if $entry->msb;
  } elsif ($entry && $entry->msb && $prevstat == 0 
	  && !$entry->msb->hasBeenCompleted) {
    # Edge case. If this entry was the only entry in the MSB successfully
    # observed AND the MSB itself was removed from the queue (using
    # DISPOSE MSB) we still need to invoke the msbcomplete callback.
    # We determine what state we are in by first seeing if this
    # is the first completed observation in the MSB and then by seeing
    # if the MSB has been "completed" previously

    # If those conditions are okay, finally, we go through the queue
    # itself to determine whether this entry is currently on the queue
    my $found = $self->qcontents->getindex( $entry );
    if (!defined $found) {
      print "Completing MSB that has been cut from queue whilst first obs is being observed\n";
      $self->msbcomplete->($entry);
      $entry->msb->hasBeenCompleted(1) if $entry->msb;
    }
  }

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


=item B<messages>

Retrieve all the messages, and their associated statuses,
that have been stored from the backend task.

 ($statuses, $messages) = $be->messages;

Returns references to two arrays. The number of elements in the status
array will match the number of elements in the messages array.

These messages will only be returned once (ie the pending queue
is cleared during this call).

Empty list is returned if we have no pending messages.

Note that messages can be present even if the queue is accepting
again. Care must be taken that the method reading these messages clears
the message stack before assuming further action can be taken.

=cut

sub messages {
  my $self = shift;

  # Store all the status and message values
  # in a slightly different layout to the internal view.
  # Clears any pending messages

  my @allmsgs;
  my @stats;
  while (my ($st,$msg) = $self->_shiftmessage) {
    push(@stats, $st);
    push(@allmsgs, $msg);
  }

  # Return empty list if no messages
  # else return the references
  if (scalar(@stats)) {
    return (\@stats, \@allmsgs);
  } else {
    return ();
  }
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

=begin __PRIVATE_METHODS__

=head2 Private Methods

These methods are not part of the public interface. They control
the caching of messages from the backend subsystem.

=over 4

=item B<_pending>

Array of arrays containing messages (and associated status) that have
been recieved from the remote task and that are waiting to be read by
the C<messages> method.

The first element in each array is the status, the second element
is the actual message. Use the C<_good> method to indicate good status.

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

=item B<_good>

Class method that returns the internal representation of a good message
status.

=cut

sub _good {
  return GOOD_STATUS;
}

=back

=end __PRIVATE_METHODS__

=head1 SEE ALSO

L<Queue>, L<Queue::Contents>

=head1 AUTHOR

Tim Jenness E<lt>t.jenness@jach.hawaii.eduE<gt>

Copyright (C) 1999-2002 Particle Physics and Astronomy Research Council.
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
