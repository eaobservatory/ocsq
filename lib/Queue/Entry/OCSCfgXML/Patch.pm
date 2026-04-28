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

use DateTime;
use OMP::General;
use JCMT::TCS::Pong;

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
    my $obsArea = $cfg->tcs->getObsArea();
    my $scanPattern = (defined $obsArea) ? $obsArea->scan_pattern() : undef;

    my $result = eval {
        my @messages = ();

        push @messages, patch_kuntur_maser($cfg)
            if $instrument eq 'FE_KUNTUR'
            and comment_matches_type('D', 0, $comment);

        push @messages, patch_pong_high_elevation($cfg)
            if $instrument eq 'SCUBA2'
            and (defined $scanPattern)
            and ('CURVY_PONG' eq uc $scanPattern);

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

=item B<patch_pong_high_elevation>

If this is a pong 900" map at high elevation, adjust the parameters
for a slower scan.

=cut

sub patch_pong_high_elevation {
    my $cfg = shift;

    my $tcs = $cfg->tcs;
    my $duration = $cfg->duration;
    my $jos = $cfg->jos;

    my @messages = ();

    # Parameters:
    # Elevation above which to adjust the scan parameters.
    my $elevation_limit = 70;

    # Time of each sequence step.
    my $eff_step_time = $jos->step_time * 1.16;

    # Maximum amout by which the JOS_MIN parameter may increase.
    my $max_sequence_steps_factor = 1.05;

    # List of new scan parameters to apply.
    my %override = (
        900 => {VELOCITY => 190, DY => 60},
    );

    my $obsArea = $tcs->getObsArea();
    my $target = $tcs->getTarget();

    return @messages unless defined $target;

    # Configure start datetime of target object.
    my $usenow_orig = $target->usenow();
    my $datetime_start = DateTime->now();
    $target->usenow(0);
    $target->datetime($datetime_start);

    my $el_deg_start = $target->el()->degrees();
    my $ha_hrs_start = $target->ha()->hours();
    my $el_transit = $target->transit_el();  # (Do not get degrees as may be undef.)

    my $datetime_dur = DateTime::Duration->new(seconds => $duration->seconds());
    my $datetime_end = $datetime_start + $datetime_dur;

    $target->datetime($datetime_end);
    my $el_deg_end = $target->el()->degrees();
    my $ha_hrs_end = $target->ha()->hours();

    # Restore original datetime usenow setting
    $target->usenow($usenow_orig);

    my $over_limit = $el_deg_start > $elevation_limit
            || $el_deg_end > $elevation_limit;

    if ($ha_hrs_start < 0 and $ha_hrs_end > 0 and defined $el_transit) {
        $over_limit ||= $el_transit->degrees > $elevation_limit;
    }

    return @messages unless $over_limit;

    my %area = $obsArea->maparea();
    my %scan = $obsArea->scan();

    return @messages unless defined $area{'HEIGHT'}
        and defined $area{'HEIGHT'};

    my $time_per_map_orig = JCMT::TCS::Pong::get_pong_dur(%area, %scan);

    my $changed = 0;

    foreach my $size (keys %override) {
        next unless $size == $area{'HEIGHT'} and $size == $area{'WIDTH'};
        $obsArea->scan(PATTERN => 'CURVY_PONG', %{$override{$size}});
        $changed = 1;
        push @messages, 'Rewrote scan parameters for pong '
            . $size
            . ' because elevation above '
            . $elevation_limit;
        last;
    }

    return @messages unless $changed;

    # Scan parameters have changed, so need to re-calculate the timing.
    %area = $obsArea->maparea();
    %scan = $obsArea->scan();
    my $time_per_map_final = JCMT::TCS::Pong::get_pong_dur(%area, %scan);

    my @posang = $obsArea->posang();

    my $ref_pa = $posang[0]->degrees();
    my $npatterns_orig = scalar @posang;

    my $npatterns = OMP::General::nint(
        $npatterns_orig * $time_per_map_orig / $time_per_map_final);

    $npatterns = 1 if 1 > $npatterns;

    my $jos_min_old = $jos->jos_min();
    my $jos_min_new = undef;

    # Need to recalculate $jos_min_new either if we never calculated it,
    # or it got too big, in which case we try to sort it out by
    # reducing the number of patterns.
    while ((! defined $jos_min_new)
            or $jos_min_new > $jos_min_old * $max_sequence_steps_factor
                && $npatterns > 1) {
        # Do not adjust if we didn't try calculating $jos_min_new yet.
        $npatterns -- if defined $jos_min_new;

        $jos_min_new = OMP::General::nint(
            $npatterns * $time_per_map_final / $eff_step_time);
    }

    $jos->jos_min($jos_min_new);

    return @messages unless $npatterns != $npatterns_orig;

    # Number of times round the pong map has changed, so regenerate
    # the list of position angles.
    my $delta = 90 / $npatterns;

    # Code copied from the translator
    @posang = map {$ref_pa + ($_ * $delta)} (0 .. $npatterns - 1);
    $obsArea->posang(
        map {Astro::Coords::Angle->new($_, units => 'degrees')}
        @posang);

    push @messages, 'Rewrote pong position angles for '
        . $npatterns
        . ' times round map instead of '
        . $npatterns_orig;

    return @messages;
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
