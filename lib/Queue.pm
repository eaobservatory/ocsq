package Queue;

=head1 NAME

Queue - Generic Queue class containing Contents and Backend objects

=head1 SYNOPSIS

  use Queue;

  $Q = new Queue;

  $Q->contents->addback(@entries);

  $Q->stopq;
  $Q->startq;

  $Q->backend->poll;

=head1 DESCRIPTION

This class provides a container for Queue::Contents and Queue::Backend
objects. It can be used to make sure that Queue::Entry objects
stored in Queue:Contents match that required by a Queue::Backend
object.

=cut

use strict;
require Queue::Contents;
require Queue::Backend;
require Queue::Entry;

our $VERSION = '0.01';

=head1 METHODS

The following methods are provided:

=head2 Constructors

=over 4

=item new

This is the Queue constructor. It initalises Backend and Contents
objects and associates them with the Queue.

  $Q = new Queue;

=cut

sub new {
  my $proto = shift;
  my $class = ref($proto) || $proto;

  my $q = {};

  bless $q, $class;

  $q->{Contents} = new Queue::Contents;
  $q->{Backend}  = new Queue::Backend;
  $q->{EntryClass} = 'Queue::Entry';

  # Make sure that the backend knows about the contents
  $q->backend->qcontents($q->{Contents});

  return $q;
}

=back

=head2 Accessors

=over 4

=item contents

Return the object associated with the Queue::Contents.

=cut

sub contents {
  my $self = shift;
  if (@_) {
    my $contents = shift;
    if (UNIVERSAL::isa($contents, 'Queue::Contents')) {
      $self->{Contents} = $contents;
    } else {
      warn "Argument supplied to contents() [$contents] is not a Queue::Contents object - ignoring\n" if $^W;
    }
  }
  return $self->{Contents};
}

=item backend

Return the object associated with the Queue::Backend.

=cut

sub backend {
  my $self = shift;
  if (@_) {
    my $be = shift;
    if (UNIVERSAL::isa($be, 'Queue::Backend')) {
      $self->{Backend} = $be;
    } else {
      warn "Argument supplied to backend() [$be] is not a Queue::Backend object - ignoring\n" if $^W;
    }
  }
  return $self->{Backend};
}

=item entryClass

Returns the class of entries required by this queue. The base class
simply uses Queue::Entry objects. This method can be used to create
the correct type of object for the queue.

  $class = $Q->entryClass;

=cut

sub entryClass {
  my $self = shift;
  $self->{EntryClass} = shift if @_;
  return $self->{EntryClass};
}


=back

=head2 Queue control

=over 4

=item startq

Start the queue (ie set the qrunning() flag in the backend).

  $Q->startq;

=cut

sub startq {
  my $self = shift;
  $self->backend->qrunning(1);
}

=item stopq

Stop the queue (ie set the qrunning() flag in the backend).

  $Q->stopq;

=cut

sub stopq {
  my $self = shift;
  $self->backend->qrunning(0);
}

=back

=cut

1;

=head1 SEE ALSO

L<Queue::Backend>, L<Queue::Contents>

=head1 AUTHOR

Tim Jenness E<lt>t.jenness@jach.hawaii.eduE<gt>
(C) 1999-2002 Copyright Particle Physics and Astronomy Research Council.
All Rights Reserved.

=cut
