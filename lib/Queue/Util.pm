package Queue::Util;

=head1 NAME

Queue::Util - Miscellaneous utility functions for the queue

=head1 DESCRIPTION

Miscellaneous utilities for the queue.

=head1 FUNCTIONS

=over 4

=cut

use strict;

use parent qw/Exporter/;

our @EXPORT_OK = qw/comment_matches_type/;

=item B<comment_matches_type>

Determines whether the type specifier in square brackets at the
start of the comment includes the given single-character type code.

    if (comment_matches_type($type, $include_typeless, $comment)) {
        ...
    }

See C<Tk::OCSQMonitor::source_is_type> for more details about source types.

=cut

sub comment_matches_type {
    my $type = shift;
    my $include_typeless = shift;
    my $comment = shift;

    unless ($comment =~ /^\[(\w+)\]/) {
        return $include_typeless;
    }

    my $code = $1;

    foreach my $char (split //, $type) {
        return 1 unless -1 == index $code, $char;
    }

    return 0;
}

1;

__END__

=back

=head1 COPYRIGHT

Copyright (C) 2023-2026 East Asian Observatory.
Copyright (C) 2014 Science and Technology Facilities Council.
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
