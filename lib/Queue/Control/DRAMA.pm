package Queue::Control::DRAMA;

=head1 NAME

Queue::Control::DRAMA - provides methods for controlling the DRAMA based queue

=head1 SYNOPSIS

  use Queue::Control::DRAMA;

  my $Q = new Queue::Control::DRAMA( 'OCSQUEUE' );

  $Q->stopq;
  $Q->exitq;
  $Q->clearq;
  $Q->startq;

=head1 DESCRIPTION

This module provides methods for controlling the DRAMA based queue.
Access is provided through an object interface to support the [unlikely]
event of a single programme talking to multiple queues.

Routines are provided for adding ODFs to the queue, stopping, starting
and clearing the queue. There should be a method for each ACTION in the
DRAMA queue.

=cut

use strict;
use warnings;
use Carp;
use DRAMA;

use vars qw/ $VERSION /;

$VERSION = '0.20';

=head1 METHODS

=head2 Constructor

=over 4

=item B<new>

Create a queue control instance. Must supply a taskname. There are
no defaults.

  $Q = new Queue::Control::DRAMA( 'OCSQUEUE' );

An optional hash argument can be supplied to specify DRAMA callbacks
that are used for some routines. Supported options are:

  -error => reference to subroutine

identical to the definition used for DRAMA obeys.

 $Q = new Queue::Control::DRAMA( 'OCSQUEUE',
                                 -error => sub { print "XXX\n" });

=cut

sub new {
  my $proto = shift;
  my $class = ref($proto) || $proto;

  my $qtask = shift;
  croak "Must supply a queue task name!"
    unless defined $qtask;

  # Slurp all remaining options
  my %args = @_;

  my $Q = bless { QTASK => $qtask }, $class;

  # Configure the object - currently be restrictive
  for my $m (qw/ -error /) {
    next unless exists $args{$m};
    # convert to a method [drop the -]
    my $method = $m;
    $m =~ s/^-//;
    $Q->$method( $args{$m});
  }

  return $Q;
}

=back

=head2 Accessor Methods

=over 4

=item B<qtask>

Return the name of the DRAMA task that is running the queue.

  $name = $Q->qtask;

=cut

sub qtask {
  my $self = shift;
  return $self->{QTASK};
}

=item B<error>

Callback associated with DRAMA errors.

  $cb = $Q->error;
  $Q->error( \&blah );

=cut

sub error {
  my $self = shift;
  if (@_) {
    my $cb = shift;
    croak "error: Must supply a code ref"
      unless ref($cb) eq 'CODE';
    $self->{CBError} = $cb;
  }
  return $self->{CBError};
}

=back

=head2 Queue Control

=over 4

=item B<startq>

Start the queue. No arguments or return values.

 $Q->startq;

=cut

sub startq {
  my $self = shift;
  obeyw $self->qtask, 'STARTQ';
}

=item B<stopq>

Stop the queue. No arguments or return values.

 $Q->stopq;

=cut

sub stopq {
  my $self = shift;
  obeyw $self->qtask, 'STOPQ';
}

=item B<exitq>

Cause the queue task to exit.
No arguments or return values.

 $Q->exitq;

=cut

sub exitq {
  my $self = shift;
  obeyw $self->qtask, 'EXIT';
}

=item B<clearq>

Clear all entries in the queue (including the paste buffer)
No arguments or return values.

 $Q->clearq;

=cut

sub clearq {
  my $self = shift;
  obeyw $self->qtask, 'CLEARQ';
}

=item B<suspendmsb>

Suspend the currently highlighted MSB.

=cut

sub suspendmsb {
  my $self = shift;
  my %args;
  $args{-error} = $self->error if defined $self->error;
  obeyw $self->qtask, 'SUSPENDMSB', \%args;
}

=item B<cutmsb>

Dispose the MSB that i

 $Q->cutmsb;

=cut

sub cutmsb {
  croak "not finished - need to worry about cutmsb vs disposemsb";
  my $self = shift;
  my %args;
  $args{-error} = $self->error if defined $self->error;
  obeyw $self->qtask, 'CUTMSB', \%args;
}



=item cutq(position, number)

Cut entries from the queue and copy them to the paste buffer.
Two arguments are required:

  position - the position to start the cut (starts at position 1)
  number   - number of items to cut from the queue. 

=cut


# CUTQ
sub cutq {
  my $self = shift;
  croak 'usage: cutq posn number' unless scalar(@_) == 2;
  my $posn = shift;

  croak "Supplied position is not an integer: $posn"
    unless $posn =~ /^\d+$/;

  my $ncut = shift;

  croak "Supplied cut is not an integer: $ncut"
    unless $ncut =~ /^\d+$/;

  my $arg = Arg->Create;
  my $status = new DRAMA::Status;
  $arg->Puti('POSN',$posn,$status);
  $arg->Puti('NCUT',$ncut,$status);

  # Send the obey
  obeyw($self->qtask,"CUTQ",$arg);
}

=item B<msbcomplete>

Indicate that the MSB is complete.

  $Q->msbcomplete( $userid, $tstamp, $accept, $reason );

where $accept is -1 to remove the MSB from the pending list
without action, 0 rejects the MSB, and 1 accepts the MSB.

The userid must be a valid OMP userid.

=cut

sub msbcomplete {
  my $self = shift;
  my ($userid, $tstamp, $accept, $reason) = @_;

  DRAMA::ErsPush();
  my $status = new DRAMA::Status;
  my $arg = Arg->Create;
  $arg->PutString("Argument1",$tstamp, $status);
  $arg->PutString("Argument2",$accept, $status);


  # A user [I could verify it here...]
  $arg->PutString("Argument3", $userid, $status)
    if $userid;

  # Make sure we have content
  if (defined $reason && length($reason) > 0 && $reason =~ /\w/) {
    $arg->PutString("Argument4", $reason, $status);
  }

  my %obeyargs;
  $obeyargs{-deletearg} = 0;
  $obeyargs{-error} = $self->error if defined $self->error;

  $arg->List( $status);

  # Run the actual obey
  if ($status->Ok) {
    obey($self->qtask,"MSBCOMPLETE",$arg, \%obeyargs);
    print "Sent MSBCOMPLETE obey to queue\n";
  } else {
    print "Error forming arguments for MSBCOMPLETE obey!\n";
    $status->Flush();
  }


  DRAMA::ErsPop();

}


=back

=head1 REQUIREMENTS

Requires the perl/DRAMA module. The DRAMA system must be initialised
before using these routines.

=head1 SEE ALSO

L<DRAMA>, L<Queue>, L<Tk::OCSQMonitor>

=head1 AUTHOR

Tim Jenness E<lt>t.jenness@jach.hawaii.edu)E<gt>

Copyright (C) Particle Physics and Astronomy Research Council 1999, 2002-2003.
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
