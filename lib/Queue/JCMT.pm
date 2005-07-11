package Queue::JCMT;

=head1 NAME

Queue::JCMT - JCMT version of the basic queue

=head1 SYNOPSIS

  use Queue::JCMT;

  $q = new Queue::JCMT;

=head1 DESCRIPTION

This is the JCMT specific queue. It uses C<Queue::Backend::JACInst> as
the backend and expects entries of class C<Queue::Entry::SCUBAODF> and
C<Queue::Entry::OCSCfgXML>.

=cut

use 5.006;
use strict;
use warnings;
use Carp;
require Queue::Backend::JACInst;
require Queue::Contents::Indexed;
require Queue::Entry::SCUBAODF;

use base qw/Queue/;

=head1 METHODS

The following methods are available:

=over 4

=item new

Constructor. Creates C<Queue::Backend::JACInst> and C<Queue::Contents>
objects when creating the C<Queue::JCMT> object.

=cut

sub new {
  my $proto = shift;
  my $class = ref($proto) || $proto;

  my $q = {};

  bless $q, $class;

  # Initialise
  $q->contents(new Queue::Contents::Indexed);
  $q->backend(new Queue::Backend::JACInst);

  # Make sure that the backend knows about the contents
  $q->backend->qcontents($q->contents);

  return $q;
}

=back

=head1 ACCESSOR METHODS

=over 4

=item B<entryClass>

For JCMT the entryClass is multi-valued since it can support both
SCUBA ODFs and OCS configuration XML.

Not actually used any more now that the queue is populated using an
XML format.

=cut

sub entryClass {
  croak "EntryClass is many valued for the JCMT queue";
}


=back

=head1 SEE ALSO

L<Queue>, L<Queue::Backend>, L<Queue::Contents>, L<Queue::Entry>

=head1 AUTHOR

Tim Jenness E<lt>t.jenness@jach.hawaii.eduE<gt>

Copyright 2002-2005 Particle Physics and Astronomy Research Council.
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