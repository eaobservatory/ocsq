package Queue::SCUCD;

=head1 NAME

Queue::SCUCD - SCUBA/SCUCD version of the basic Queue

=head1 SYNOPSIS

  use Queue::SCUCD;

  $q = new Queue::SCUCD;

=head1 DESCRIPTION

This is the SCUCD specific queue. It uses Queue::Backend::SCUCD
as the backend and expects entries of class Queue::Entry::SCUBAODF
(as specified in the entryClass() method).

=cut

use 5.006;
use strict;
use warnings;
require Queue::Backend::SCUCD;
require Queue::Contents::Indexed;
require Queue::Entry::SCUBAODF;

use base qw/Queue/;

=head1 METHODS

The following methods are available:

=over 4

=item new

Constructor. Creates C<Queue::Backend::SCUCD> and C<Queue::Contents>
objects when creating the C<Queue::SCUCD> object.

=cut

sub new {
  my $proto = shift;
  my $class = ref($proto) || $proto;

  my $q = {};

  bless $q, $class;

  # Initialise
  $q->contents(new Queue::Contents::Indexed);
  $q->backend(new Queue::Backend::SCUCD);
  $q->entryClass('Queue::Entry::SCUBAODF');

  # Make sure that the backend knows about the contents
  $q->backend->qcontents($q->contents);

  return $q;
}

=back

=cut

1;

=head1 SEE ALSO

L<Queue>, L<Queue::Backend>, L<Queue::Contents>, L<Queue::Entry>

=head1 AUTHOR

Tim Jenness E<lt>t.jenness@jach.hawaii.eduE<gt>
Copyright 2002 Particle Physics and Astronomy Research Council.
All Rights Reserved.

=cut
