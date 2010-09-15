package Queue::Constants;

=head1 NAME

Queue::Constants - Constants defined for use in the queue system

=head1 SYNOPSIS

  use Queue::Constants;

  $qstate = Queue::Constants::QSTATE__EMPTY

=head1 DESCRIPTION

Global constants to be shared by the queue and the queue monitor.

=cut

use strict;
use warnings;


=head1 CONSTANTS

=over 4

=item B<QSTATE__BCKERR>

Queue stopped due to backend error.

=cut

use constant QSTATE__BCKERR => 1;

=item B<QSTATE__EMPTY>

Queue will soon be empty.

=cut

use constant QSTATE__EMPTY => 2;

=back

=head1 AUTHOR

Tim Jenness E<lt>t.jenness@jach.hawaii.eduE<gt>

Copyright (C) 2009 Science & Technology Facilities Council.
All Rights Reserved.

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License as
published by the Free Software Foundation; either version 3 of
the License, or (at your option) any later version.

This program is distributed in the hope that it will be
useful, but WITHOUT ANY WARRANTY; without even the implied
warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public
License along with this program; if not, write to the Free
Software Foundation, Inc., 59 Temple Place, Suite 330, Boston,
MA 02111-1307, USA

=cut

1;
