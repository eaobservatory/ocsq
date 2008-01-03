package Queue::JitDRAMA;

=head1 NAME

Queue::JitDRAMA - Load Jit and DRAMA modules in correct order

=head1 SYNOPSIS

  use Queue::JitDRAMA;

=head1 DESCRIPTION

Loads the Jit and DRAMA modules in the correct order, allowing for the
correct functionality of the Jit overrides.

=cut

# use JAC::ITSRoot;
use Jit;
use DRAMA;

=head1 AUTHOR

Tim Jenness E<lt>t.jenness@jach.hawaii.eduE<gt>.

Copyright (C) 2007 Science and Technology Facilities Council.
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
