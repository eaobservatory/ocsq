package Queue::Backend::JACInst;

=head1 NAME

Queue::Backend::JACInst - Queue interface to the JAC instrument task

=head1 SYNOPSIS

    use Queue::Backend::JACInst;

    $be = new Queue::Backend::JACInst;
    $be->send_entry($be->qcontents->nextentry)
        if $be->accepting;

=head1 DESCRIPTION

This class can be used to send queue entries to the JAC instrument
task running either at UKIRT or JCMT.

The connection to JAC_INST must use DRAMA. This means that an entry is
sent to the task as a DRAMA message and the entry is deemed to have been
completed when that EXECUTE action completes. This means that the
callback for the drama obey, assuming we are running in non-blocking
mode, must set a state variable in the object when the obey has
completed (the C<poll> method will then simply check that variable).

Messages from the instrument task will be intercepted and stored in the object
for retrieval by the C<messages> method.

The entry is sent using a non-blocking OBEY and returns immediately to
the queue main loop which will reschedule (querying this class) until
the OBEY completes.

Since the messages are sent using DRAMA, assume that we are
always connected to the remote task even if the remote task
is dead (since that will trigger an error anyway). This is
easier than trying to POLL the remote task.

The DRAMA system must already have been initialised.

=cut

use 5.006;
use strict;
use warnings;
use Carp;

use base qw/Queue::Backend/;

use Queue::JitDRAMA;
use Time::Piece qw/:override/;
use Term::ANSIColor qw/colored/;

=head1 METHODS

=head2 Class Methods

=over 4

=item B<TASK>

Name of the task to be controlled. Defaults to "JAC_INST" but can be
set to other values for testing.

    $task = Queue::Backend::JACInst->TASK;

=cut

{
    my $TASK = 'JAC_INST';

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
constructor except that for DRAMA, the connection should not be
initiated since it is always assumed to be active (the system must be
loaded as part of the queue runup). - C<accepting> is
set to true immediately.

    $be = new Queue::Backend::JACInst;

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

Set to false when the instrument is actively observing (ie the
obey is still active).

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

Send the supplied filename name to the instrument task (generally JAC_INST).

    $status = $be->_send($filename, $entry);

Returns immediately, generally with good status (since the action
is sent with a non-blocking obey).

The entry itself is an argument in case it needs to be modified
during callbacks (eg to change its status on completion).

The returned status is a Perl status - true if everything was okay.
False otherwise.

=cut

sub _send {
    my $self = shift;
    my $filename = shift;
    my $entry = shift;

    my $TASK = $self->TASK;

    # Create argument structure
    my $arg = Arg->Create();
    my $status = new DRAMA::Status;
    $arg->PutString("Argument1", $filename, $status);

    # change the status of the entry to SENT
    $entry->status("SENT");

    # Create callbacks

    # First the success handler
    my $success = sub {
        # print "SUCCESS\n";
        $self->_pushmessage($self->_good, "Observation completed successfully");

        # change status
        $entry->status("OBSERVED");

        # Do post-observation stuff. Includes incrementing the index.
        # Only want to do this if the observations was completed succesfully
        $self->post_obs_tidy($entry);
    };

    my $error = sub {
        my ($lstat, $msg) = @_;

        # change status to bad
        $entry->status("ERROR");

        # print "ERROR HANDLER: $msg\n";
        $self->_pushmessage($lstat,
            colored("##", "bold red")
            . colored("$TASK:", 'red')
            . $msg);
    };

    my $complete = sub {
        # The queue must be configured to accept again even if an error was
        # triggered. The assumption is that the queue will be stopped on
        # error anyway but we must be able to accept when the queue restarts.
        $self->accepting(1);
    };

    my $info = sub {
        my @msg = @_;
        print "REMOTE INFO MESSAGE: $_\n" for @msg;
        $self->_pushmessage($self->_good, "$TASK: $_") for @msg;
    };

    # infofull gives us full control of messages so we can distinguish error
    # from Msg messages. This will be used if the DRAMA module is new enough
    # but will use -info otherwise. so -info should stay around for the migration
    # period.
    my $infofull = sub {
        my $rtask = shift;
        my @messages = @_;

        my $err = 0;
        for my $msg (@messages) {
            my $prefix;
            my $task = "$rtask:";
            my $status;
            if (! exists $msg->{status}) {
                $status = $self->_good;
                $prefix = '';
                $err = 0;  # not in an error
                $task = colored($task, 'green');
            }
            else {
                $status = $msg->{status};
                if (! $err) {
                    # first error chunk
                    $err = 1;
                    $prefix = "##";
                }
                else {
                    $prefix = "# ";
                }
                $task = colored($task, 'red');
                $prefix = colored($prefix, 'bold red');
            }

            my $pretext = $prefix . $task;
            print $pretext . $msg->{message} . "\n";
            $self->_pushmessage($status, $pretext . $msg->{message});
        }
    };

    # Indicate that we are not accepting at the moment
    $self->accepting(0);

    my $retstatus = 1;
    $self->_pushmessage($self->_good,
        "Sending entry to instrument task $TASK...");

    # do the obey and return immediately but make sure we set
    # up triggers
    # On completion we need to indicate that we are accepting new entries
    # on success we should probably store a message on the stack
    # on error put the message on the stack and error code
    obey $TASK, "OBSERVE", $arg,
        {
        -deletearg => 0,
        -success => $success,
        -error => $error,
        -complete => $complete,
        -info => $info,
        -infofull => $infofull,
        };

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

    $modentry = $be->addFailureContext;

Returns immediately if no C<failure_reason> is stored in the object.

In some failure modes the entry can be fixed by looking in other queue
entries. If this occurs the modified entry will be returned.

=cut

sub addFailureContext {
    my $self = shift;

    # Get the failure object and the queue contents
    my $r = $self->failure_reason;
    return unless $r;

    # Get the queue contents
    my $q = $self->qcontents;

    # Set the index of the entry
    $r->index($q->curindex);

    # Get the current entry as reference in case we can fix it
    my $curentry = $q->curentry;

    # Get current time
    my $time = gmtime();
    $r->details->{TIME} = $time->datetime;

    # True if we hit an MSB boundary
    my $boundary = 0;

    if ($r->type eq 'MissingTarget' || $r->type eq 'NeedNextTarget') {
        # Need to go through the queue starting at the current index
        # looking for target information OR an indication that we are
        # interested in a calibrator (in which case we stop since we know
        # the list of calibrators)
        my $index = $q->curindex;
        my ($target, $iscal, $havemissing);
        while (defined(my $entry = $q->getentry($index))) {
            # Abort if we hit an MSB boundary on the previous loop
            # NeedNextTarget does not care about MSB boundaries
            # so we can continue
            last if ($boundary && $r->type ne 'NeedNextTarget');

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

            # if we have got this far and have found a missing target
            # we can't stop because we need to look for some context
            # for the missing target. Do not override an earlier "miss"
            $havemissing = $entry->isMissingTarget
                unless $havemissing;

            $index ++;
        }

        $r->details->{FOLLOWING} = 1 if ($target || $iscal);

        # if we did not find a target or a calibrator
        # reverse the sense of the search and look behind us
        # since it may be that we should be using the same
        # target as the previous observation
        # Do not go above the firstObs of the MSB though
        # Do not do this for NeedNextTarget which needs to look forward
        # unless we found a missing target going forward
        if (! $target
                && ! $iscal
                && ($r->type ne 'NeedNextTarget'
                    || ($r->type eq 'NeedNextTarget' && $havemissing))) {
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

                $index --;
            }
            $r->details->{FOLLOWING} = 0 if ($target || $iscal);
        }

        # We now either have a valid target or an indication of CAL-ness
        # If we have nothing at all we can not help the observer
        $r->details->{CAL} = 0;
        if ($iscal) {
            print "REQUEST FOR CALIBRATOR\n";
            $r->details->{CAL} = 1;
        }
        elsif ($target) {
            if ($r->type eq 'NeedNextTarget' && !$havemissing) {
                # we can fix up the entry unless we found
                # an entry with a missing target and need to fill
                # that in first
                $curentry->setTarget($target);

                # Is this a SCUBA-2 setup observation?  If so, try
                # to adjust the slew time.
                $self->_trackFollowingObservation($curentry, $q)
                    if $curentry->instrument() eq 'SCUBA2'
                    and $curentry->entity()->obsmode() =~ /^setup/;

                return $curentry;
            }
            else {
                # get the current az and el
                print "TARGET INFORMATION: " . $target->status . "\n";
                my $un = $target->usenow;
                $target->usenow(0);
                $target->datetime($time);
                print "EPOCH TIME: " . $target->datetime->epoch() . "\n";
                $r->details->{AZ} = $target->az->radians;
                $r->details->{EL} = $target->el->radians;
                my $name = $target->name;
                $r->details->{REFNAME} = $name if defined $name;
                $target->usenow($un);
            }
        }
        else {
            delete $r->details->{FOLLOWING};
        }
    }
    else {
        croak "Do not understand how to process this Failure object [" . $r->type . "]\n";
    }
    return;
}

=item B<_trackFollowingObservation>

Helper method for addFailureContext to look forward through
the queue for observations with the same target in the same
MSB, and add their slew tracking time to that of the current
observation.

This is useful for SCUBA-2 setup observations:

Setup observations are short which means that the SLEW component in the
TCS indicates that the source only has to be accessible for a short
time. This sometimes leads to the setup being followed by a science
observation that can not be completed without a big slew. The fix is to
include the following science observation in the slew estimate.

The fixup system can be used to do this because setup observations
which are automatically added by the translator will trigger the
'NeedNextTarget' event.

However we need to make sure that the setup time is not repeatedly
increased if the TSS moves back up the queue and resubmits the setup
observation, therefore we use the original track time stored in
the queue entry object.

=cut

sub _trackFollowingObservation {
    my $self = shift;
    my ($curentry, $q) = @_;

    my $index = $q->curindex() + 1;
    my $reftarget = $curentry->getTarget();
    my $total = 0;
    my $num_obs = 0;

    while (defined(my $entry = $q->getentry($index))) {
        # Check that the target didn't change;
        my $target = $entry->getTarget();
        last if "$target" ne "$reftarget";

        my $time = $entry->getSlewTrackTime();
        if ($time) {
            $total += $time;
            $num_obs ++;
        }

        # If this entry is the end of an MSB do not go further.
        last if $entry->lastObs;

        $index ++;
    }

    if ($total) {
        my $time = $curentry->getOriginalTrackTime();
        if ($time) {
            my $newtime = $time + $total;
            $curentry->setSlewTrackTime($newtime);
            $curentry->addWarningMessage(
                colored('SLEW:', 'yellow')
                . ' adjusted tracking time from ' . $time . ' to ' . $newtime
                . colored(' covering ' . $num_obs . ' observation' . ($num_obs == 1 ? '' : 's'), 'yellow')
            );
        }
    }
}

1;

__END__

=back

=head1 SEE ALSO

L<Queue>, L<Queue::Backend>, L<Queue::Entry>

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
