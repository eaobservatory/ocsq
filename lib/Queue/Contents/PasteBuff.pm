package Queue::Contents::PasteBuff;

=head1 NAME

Queue::Contents::PasteBuff - Manipulate contents of a queue with Paste Buffer

=head1 SYNOPSIS

  use Queue::Contents::PasteBuff;

  $Q = new Queue::Contents::PasteBuff;

  $Q->addback(@entries);
  $Q->addfront(@entries);
  @cut = $Q->cutq(5);
  $Q->pasteq(4,@cut);

  $Q->clearq;

  $top = $Q->popq;

  @description = $Q->stringified;
  @pastebuffer = $Q->pastebuffer->stringified;

=head1 DESCRIPTION

This class provides methods for manipulating the contents of a
stack-based Queue similar to the original SCUBA QUEMAN.  The Queue
manipulates Queue::Entry objects. As entries are queued they pop off
the top of the stack. Entries can be pushed onto the bottom of the
stack or on the top as well as being cut from the middle. When entries
are cut from the queue they are stored in a paste buffer so they can
be recalled later.

=cut

use strict;
use Carp;
use base qw/ Queue::Contents /;

=head1 METHODS

The following methods are provided:

=head2 Constructors

=over 4

=item B<new>

This is the Contents constructor. Accepts an array of Queue::Entry
objects to initialise the Queue contents.

  $queue = new Queue::Contents::PasteBuff(@entries);

The paste buffer is implemented as a normal Queue::Contents
object.

=cut

sub new {
  my $proto = shift;
  my $class = ref($proto) || $proto;

  # Check for optional options hash and pre-process it
  # To extract the PASTE information
  my %options = ();
  %options = %{ shift() } if (@_ && ref($_[0]) eq 'HASH');

  # Delete PASTE and replace with PasteBuffer
  # creating a new queue if PASTE is false (if it is false
  # than we are the primary queue and we need a pastebuffer)
  # The paste buffer itself must be a normal queue (which means we
  # can get rid of all the $ispaste stuff.
  $options{PasteBuffer} = new Queue::Contents();

  # Use base class constructor
  my $q = $class->SUPER::new(\%options, @_);

  # Return the blessed reference
  return $q;
}

=back

=head2 Accessor Methods

=over 4

=item B<pastebuffer>

Returns the object associated with the current paste buffer. The
paste buffer is used by the cutq() and pasteq() methods.

  $buffer_object = $queue->pastebuffer;  

Accepts a Queue::Contents object as argument (or undef).

=cut

sub pastebuffer {
  my $self = shift;
  if (@_) {
    my $paste = shift;
    croak "pastebuffer must be of class Queue::Contents not '$paste'" 
      unless UNIVERSAL::isa($paste, "Queue::Contents")
	or not defined $paste;
    $self->{PasteBuffer} = $paste;
  }
  return $self->{PasteBuffer};
}


=back

=head2 Content Manipulation

=over 4

=item B<cutq>

Cut entries from the queue and store them in the paste buffer.

  @cut_entries = $queue->cutq($start, $num)

The entries cut from the queue are returned to the caller as well as being
stored in the paste buffer. The supplied arguments are the start position
(start counting from zero) and the number of entries to cut from the
queue. This command is similar to the Perl splice() command.

=cut

sub cutq {
  my $self = shift;
  my @cut = $self->SUPER::cutq(@_);

  # Set the paste buffer
  $self->pastebuffer->contents(@cut);

  return @cut;
}


=item B<pasteq>

Paste items into the queue at the specified position. If no more
arguments are supplied, the contents of the paste buffer are inserted
into the queue (and the paste buffer is cleared). If extra arguments
are supplied, they are used rather than the paste buffer (which is
left unchanged; see also the C<insertq> method). This command is
similar to the Perl splice() command.

  $queue->pasteq(4);
  $queue->pasteq(5,@entries);

There are no return arguments.

The paste buffer is cleared.

=cut

sub pasteq {
  my $self = shift;

  croak 'Usage: $queue->pasteq(pos,[entries])' unless @_;

  # Read the first arg
  my $pos = shift;

  # Get the paste buffer (or the remaining args)
  my @paste;
  if (@_) {
    @paste = @_;
  } else {
    # Read the paste buffer and clear it
    @paste = $self->pastebuffer->contents;
    $self->pastebuffer->clearq;
  }

  # Insert
  $self->insertq( $pos, @paste );

  return;
}

=back

=head1 SEE ALSO

L<Queue>, L<Queue::Contents>, L<Queue::Entry>

=head1 AUTHOR

Tim Jenness E<lt>t.jenness@jach.hawaii.eduE<gt>
(C) 1999-2002 Particle Physics and Astronomy Research Council.
All Rights Reserved.

=cut


1;
