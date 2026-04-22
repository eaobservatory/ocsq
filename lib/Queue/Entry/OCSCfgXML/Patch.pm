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

use Queue::Util qw/comment_matches_type/;

=item B<get_patched_entity>

Get the entity (C<JAC::OCS::Config> object) and apply any suitable patches
to it.  Return the entity (probably the same object, with modifications
applied, rather than an edited copy) and any relevant messages.

=cut

sub get_patched_entity {
    my $self = shift;
    my $cfg = $self->entity;
    return undef unless defined $cfg;

    my $instrument = $self->instrument;
    my $comment = $self->getTargetComment;

    my $result = eval {
        my @messages = ();

        push @messages, patch_kuntur_maser($cfg)
            if $instrument eq 'FE_KUNTUR'
            and comment_matches_type('D', 0, $comment);

        \@messages;
    };

    # Return the config. plus accumulated messages or error.
    return $cfg, ((defined $result) ? @$result : $@);
}

=back

=head1 PATCH FUNCTIONS

=over 4

=item B<patch_kuntur_maser>

If the configuration has a Kuntur tuning for only CO 6-5, change it
to the 658 GHz water maser line.

=cut

sub patch_kuntur_maser {
    my $cfg = shift;

    # Settings to apply for the 658 GHz maser line.
    my $rest_freq = 658.006251;
    my $molecule = 'H2O v2';
    my $transition = '1 1 0 1 - 1 0 1 1';
    my $imag_key = 'trNOLINE';
    my $line_key = 'trCO6-5';

    # Get references to relevant parts of the configuration and check
    # the necessary information is present, or the tuning is not CO 6-5.
    my $fe = $cfg->frontend;
    die 'Frontend information not available'
        unless defined $fe;

    return () if abs($fe->rest_frequency - 691.473) > 0.001;

    my $inst = $cfg->instrument_setup;
    die 'Instrument information not available'
        unless defined $inst;

    my $acsis = $cfg->acsis;
    die 'ACSIS configuration not available'
        unless defined $acsis;

    my $ll = $acsis->line_list;
    die 'ACSIS line list not available'
        unless defined $ll;

    my %lines = $ll->lines;
    die 'Unexpected number of spectral lines'
        unless 2 == scalar keys %lines;
    die 'Expected image spectral line key missing'
        unless exists $lines{$imag_key};
    die 'Expected main spectral line key  missing'
        unless exists $lines{$line_key};

    # Compute image frequency, assuming MSB was translated for an instrument
    # with changeable if_center_freq and without redshift.
    my $sideband = $fe->sideband();
    my $if_freq = $inst->if_center_freq();
    my $imag_freq = $rest_freq + (($sideband =~ /LSB/i) ? 2.0 : -2.0) * $if_freq;

    # Checks complete, apply settings to the configuration.
    # (Note that we modify the configuration object, so we can not apply
    # more checks and potentially stop part way through.)
    $fe->rest_frequency($rest_freq);

    $inst->wavelength(Astro::WaveBand->new(
        Frequency => $rest_freq * 1.0e9,
    )->wavelength);

    $lines{$line_key}->molecule($molecule);
    $lines{$line_key}->transition($transition);
    $lines{$line_key}->restfreq($rest_freq * 1.0e9);
    $lines{$imag_key}->restfreq($imag_freq * 1.0e9);

    return "Changed tuning to $molecule $transition";
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
