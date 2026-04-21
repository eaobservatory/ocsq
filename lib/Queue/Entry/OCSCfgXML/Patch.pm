package Queue::Entry::OCSCfgXML::Patch;

=head1 NAME

Queue::Entry::OCSCfgXML::Patch - Apply patches to OCS config before prepare

=head1 DESCRIPTION

Mix-in class for C<Queue::Entry::OCSCfgXML> providing the C<get_patched_entity>
method.

=head1 METHODS

=over 4

=cut

use strict;

=item B<get_patched_entity>

Get the entity (C<JAC::OCS::Config> object) and apply any suitable patches
to it.  Return the entity (probably the same object, with modifications
applied, rather than an edited copy) and any relevant messages.

=cut

sub get_patched_entity {
    my $self = shift;
    my $cfg = $self->entity;
    return undef unless defined $cfg;

    my @messages = ();

    return $cfg, @messages;
}

1;

__END__

=back

=head1 COPYRIGHT

Copyright (C) 2026 East Asian Observatory
All Rights Reserved.

This program is free software; you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation; either version 2 of the License, or (at your option) any later
version.

This program is distributed in the hope that it will be useful,but WITHOUT
ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
FOR A PARTICULAR PURPOSE. See the GNU General Public License for more
details.

You should have received a copy of the GNU General Public License along with
this program; if not, write to the Free Software Foundation, Inc.,51 Franklin
Street, Fifth Floor, Boston, MA  02110-1301, USA

=cut
