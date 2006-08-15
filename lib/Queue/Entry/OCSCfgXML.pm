package Queue::Entry::OCSCfgXML;

=head1 NAME

Queue::Entry::OCSCfgXML - Queue entry for JCMT OCS XML configurations

=head1 SYNOPSIS

  use Queue::Entry::OCSCfgXML;

  $entry = new Queue::Entry::OCSCfgXML('name', $cfg_object );
  $entry = new Queue::Entry::OCSCfgXML('name', $file );

  $entry->label($label);
  $entry->configure('label',$seq_object);
  $entry->entity($seq_object);
  $text = $entry->string;
  $entry->prepare;

=head1 DESCRIPTION

This class describes entries that can be manipulated by a
C<Queue::Contents> class. The particular type of entry must be a
C<JAC::OCS::Config> object.  This object is converted to a file on disk
when the entry is sent to the backend (the JCMT instrument task). The
string representation of the entry is obtained directly from the
C<JAC::OCS::Config> object.

This class is a sub-class of C<Queue::Entry>.

It is a thin layer on top of a C<JAC::OCS::Config> object.

=cut

use 5.006;
use warnings;
use strict;
use Carp;
use Time::Seconds;

use Queue::Backend::FailureReason;
use JAC::OCS::Config;
use JAC::OCS::Config::Error qw/ :try /;

use base qw/Queue::Entry/;

=head1 METHODS

The following sub-classed methods are provided:

=head2 Constructor

=over 4

=item B<new>

The sub-classed constructor is responsible for checking the second
argument to see whether it is already a C<JAC::OCS::Config> object or
if one needs to be created from a file name (if unblessed).

  $entry = new Queue::Entry::OCSCfgXML( $label, $filename);
  $entry = new Queue::Entry::OCSCfgXML( $label, $odf_object);

Once the filename has been converted into a C<JAC::OCS::Config> object
the constructor in the base class is called.

=cut

sub new {
  my ($self, $label, $thing) = @_;

  # Check to see if thing is an object
  my $entity;
  if (UNIVERSAL::isa($thing, 'JAC::OCS::Config')) {
    # looks okay
    $entity = $thing;
  } elsif (not ref($thing)) {
    # treat it as a filename
    $entity = new JAC::OCS::Config( File => $thing, validation => 0 );
  } else {
    croak "Argument to constructor is neither a JAC::OCS::Config object nor a simple scalar filename";
  }

  return $self->SUPER::new($label, $entity);
}

=back

=head2 Accessor methods

=over 4

=item B<entity>

This method stores or retrieves the C<JAC::OCS::Config> object associated with
the entry.

  $odf = $entry->entity;
  $entry->entity($odf);

=cut

sub entity {
  my $self = shift;

  if (@_) {
    my $seq = shift;
    croak 'Queue::Entry::OCSCfgXML::entity: argument is not a JAC::OCS::Config'
      unless UNIVERSAL::isa($seq, 'JAC::OCS::Config');
    $self->SUPER::entity($seq);
  }
  return $self->SUPER::entity;
}

=item B<instrument>

String describing the instrument associated with this queue entry.

  $inst = $e->instrument();

Delegated to the C<JAC::OCS::Config> C<instrument> method.

=cut

sub instrument {
  my $self = shift;
  my $entity = $self->entity;
  return "UNKNOWN" unless defined $entity;
  return $entity->instrument;
}

=item B<telescope>

String describing the telescope associated with this queue entry.
This is used for sanity checking the Queue Entry XML.

 $tel = $e->telescope();

=cut

sub telescope {
  my $self = shift;
  my $entity = $self->entity;
  croak "Telescope is not defined!" unless defined $entity;
  return $entity->telescope;
}

=back

=head2 Configuration

=over 4

=item B<configure>

Configures the object. This mainly involves checking that the second
argument is a C<JAC::OCS::Config> object. The first argument is the entry
label. This method must take two arguments.  There are no return
arguments.

  $entry->configure($label, $cfg);

=cut

sub configure {
  my $self = shift;
  croak 'Usage: configure(label,JAC::OCS::Config)' if scalar(@_) != 2;
  croak unless UNIVERSAL::isa($_[1], "JAC::OCS::Config");
  $self->SUPER::configure(@_);
}

=item B<write_entry>

Write the entry to disk. In this case uses the C<write_entry> method from
C<JAC::OCS::Config>. Returns the names of all the files that were
created.  The first file in the returned list is the "primary" file
that can be used to create a new C<Queue::Entry> object of this class.

  @files = $e->write_entry();

By default, uses the directory specified using the C<outputdir>
class method. An optional argument can be used to specify a new
output directory (useful when dumping the queue contents to a temporary
location via XML (see L<Queue::EntryXMLIO/"writeXML">).

 @files = $e->write_entry( $outputdir );

An empty return list indicates an error occurred.

No attempt is made to "fixup" or "verify" the entry prior to writing.

=cut

sub write_entry {
  my $self = shift;
  my $dir = shift;

  # Get the ODF itself
  my $cfg = $self->entity;
  return () unless defined $cfg;

  # Configure the output directory
  my $out = $dir || $self->outputdir;

  my @files = $cfg->write_entry( $out );
  return (@files);
}

=item B<prepare>

This method should be used to prepare the entry for sending to the
backend (in this case the JCMT instrument task). It does two things:

=over 4

=item 1

Writes the sequence to disk in the form of a OCS configuration XML and
configs. See the C<write_entry> method.

=item 2

Stores the name of this temporary file in the C<be_object()>.

=back

  $status = $entry->prepare;

Returns undef if everything is okay. Returns a
C<Queue::Backend::FailureReason> object if there was a problem that
could not be fixed.

The alternative is for the method to return false on error,
store the failure object in the Entry and then expect the
backend object to retrieve it when it notices there was a problem.
Otherwise we need to add exception handling throughout the queue.

=cut

sub prepare {
  my $self = shift;

  my $cfg = $self->entity;

  # Should return a reason here
  return unless defined $cfg;

  # Now verify that the ODF is okay and catch the exception
  # We do a fixup and a verify here. Note that fixup tries to correct
  # stuff that can be fixed without asking for more information
  use Term::ANSIColor;
  print colored("About to prepare\n","red");
  my $r;
  try {
    $cfg->fixup;
    $cfg->verify;
  } catch JAC::OCS::Config::Error::MissingTarget with {
    # if the target is missing we cannot send this ODF
    # so we need to package up the relevant information
    # and pass it higher up
    # The information we need from the ODF is just
    #    MODE
    #    FILTER
    print colored("Caught MissingTarget\n","cyan");
    $r = new Queue::Backend::FailureReason( 'MissingTarget',
					    MODE => $cfg->obsmode,
					    WAVEBAND => $cfg->waveband->natural,
					    INSTRUMENT => $self->instrument,
					    TELESCOPE => $self->telescope,
					  );
  } catch JAC::OCS::Config::Error with {
    # all other sequence errors can be dealt with via a fixup [maybe]
    $cfg->fixup;

    # Just in case that did not work
    $cfg->verify;

  } otherwise {
    # strange other error that we need to forward
    my $E = shift;
    $E->throw;
  };

  # if we ended up with a failure object we need to return it here
  return $r if $r;

  # Write the ODF
  my @files = $self->write_entry();
  return unless @files;

  print colored("Wrote the following configuration files:\n","cyan");
  print join("\n",map { "\t$_"} @files), "\n";

  # Store the filename in the be_object
  $self->be_object( $files[0] );

  return;
}

=item B<getTarget>

Retrieve target information from the entry in the form of an C<Astro::Coords>
object. Returns C<undef> if no target information is found.

 $c = $e->getTarget;

Does not handle REFERENCE positions.

=cut

sub getTarget {
  my $self = shift;
  return $self->entity->tcs->getTarget;
}

=item B<setTarget>

Set target information associated with the entry. Requires an
C<Astro::Coords>, C<JAC::OCS::Config::TCS::BASE>, or
C<JAC::OCS::Config::TCS> object

  $e->setTarget( $coords );

If the entry currently only has a SCIENCE tag the position
will be modified to that in the supplied argument. If the 
entry has multiple tags and the supplied argument only has one tag
all tags that share the position of the current SCIENCE value will
be modified. If the entry has multiple tags and the current entry has
many, all will be overridden.

An error occurs if multiple tags pre-exist and are not modified (maybe
because they have an absolute position).

=cut

sub setTarget {
  my $self = shift;
  my $coords = shift;

  # get the TCS specification
  my $tcs = $self->entity->tcs;

  if (defined $tcs) {
    # synchronize
    my @un = $tcs->setTargetSync( $coords );
    croak "Error setting target override because tags ".join(",",@un).
      "were not synchronized with the SCIENCE position" if @un;
  } else {
    croak "No TCS information available in configuration so can not set a target!";
  }
}

=item B<clearTarget>

Clear target information associated with the entry.

  $e->clearTarget();

=cut

sub clearTarget {
  my $self = shift;

  # get the TCS specification
  my $tcs = $self->entity->tcs;

  if (defined $tcs) {
    # note that this only clears the SCIENCE position
    $tcs->clearTarget;
  } else {
    croak "No TCS information available in configuration so can not clear a target!";
  }
}

=item B<iscal>

Returns true if the sequence seems to be associated with a
science calibration observation (e.g. a flux or wavelength
calibration). Returns false otherwise.

  $iscal = $seq->iscal();

=cut

sub iscal {
  my $self = shift;
  warn "iscal not implemented";
  return 0;
}

=item B<isGenericCal>

Returns true if the sequence seems to be associated with a
generic calibration observation such as array tests.

 $isgencal = $seq->isGenericCal();

Note that if the sequence includes both array tests and 
science observations, it is possible for a single sequence
to be a calibration and science observation.

=cut

sub isGenericCal {
  my $self = shift;
  warn "isGenericCal not implemented";
  return 0;
}

=item B<isScienceObs>

Return true if this sequence includes a science observation.

 $issci = $seq->isScienceObs;

=cut

sub isScienceObs {
  my $self = shift;
  warn "isScienceObs not implemented";
  return 1;
}

=item B<projectid>

Returns the project ID associated with this entry.

  $proj = $entry->projectid;

The base class always returns undef.

=cut

sub projectid {
  my $self = shift;
  return $self->entity->projectid;
}

=item B<msbid>

Returns the MSB ID associated with this entry.

  $msbid = $entry->msbid;

=cut

sub msbid {
  my $self = shift;
  return $self->entity->msbid;
}

=back

=head2 Display methods

=over 4

=item B<string>

Control how the entry is displayed in the queue summary.

 $string = $entry->string;

=cut

sub string {
  my $self = shift;
  my $cfg = $self->entity;
  my $posn = $self->msb_status;
  my $project = $self->projectid;
  $project = "NONE" unless defined $project;
  my $projlen = 12;
  $project = substr($project, 0, $projlen);

  # Duration
  my $duration = $self->duration;
  my $minutes;
  if (defined $duration) {
    $minutes = $duration->minutes;
  } else {
    $minutes = "0.00";
  }


  return sprintf("%-10s%-".$projlen."s %-14s%s %4.1f min",$self->status,
		 $project,$posn,$cfg->qsummary, $minutes);
}

=item B<summarize>

Returns a hash summarizing the queue entry. This is used by the C<string>
method to build up the queue entry in the queue monitor display.

The following keys are expected by the C<string> method:

=over 8

=item OBSMODE

A short string describing the observing mode.

=item WAVEBAND

A string representation of the waveband of the observation.

=item MISC

Miscellaneous other information in the form of a string.

=back

  %sum = $entry->summarize;

=back

=cut

sub summarize {
  my $self = shift;
  my $entity = $self->entity;
  return () unless defined $entity;

  my %hash;

  $hash{OBSMODE} = $entity->obsmode;
  $hash{OBSMODE} =~ s/_/ /g;

  $hash{WAVEBAND} = $entity->waveband;

  return %hash;
}

=head2 Destructors

The destructor removes the temporary file created by the
prepare() method (and stored in be_object()). The assumption
is that the file is no longer needed once it has been sent 
to the backend (the TODD).

Note that if C<write_entry> creates more than one output file
only the primary file will be deleted by the destructor. This
is probably a bug and the system should be storing the file
names independently of the C<be_object> method.

Not currentlty enabled.

=cut

#sub DESTROY {
#  my $self = shift;

#  my $file = $self->be_object;

#  if (defined $file) {
#    print "UNLINK $file\n" if -e $file;
#    unlink $file if -e $file;
#  }
#}

=head1 SEE ALSO

L<Queue::Entry>, L<Queue::Contents>, L<JAC::OCS::Config>

=head1 AUTHOR

Tim Jenness E<lt>t.jenness@jach.hawaii.eduE<gt>

Copyright (C) 2003-2005 Particle Physics and Astronomy Research Council.
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
