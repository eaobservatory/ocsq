package Queue::Entry::UKIRTSeq;

=head1 NAME

Queue::Entry::UKIRTSeq - Queue entry for UKIRT sequences

=head1 SYNOPSIS

  use Queue::Entry::UKIRTSeq;

  $entry = new Queue::Entry::UKIRTSeq('name', $seq_object );
  $entry = new Queue::Entry::UKIRTSeq('name', $file );

  $entry->label($label);
  $entry->configure('label',$seq_object);
  $entry->entity($seq_object);
  $text = $entry->string;
  $entry->prepare;

=head1 DESCRIPTION

This class describes entries that can be manipulated by a
C<Queue::Contents> class. The particular type of entry must be a
C<UKIRT::Sequence> object.  This object is converted to a file on disk
when the entry is sent to the backend (the UKIRT instrument task). The
string representation of the entry is obtained directly from the
C<UKIRT::Sequence> object.

This class is a sub-class of C<Queue::Entry>.

It is a thin layer on top of a C<UKIRT::Sequence> object.

=cut

use 5.006;
use warnings;
use strict;
use Carp;
use Time::Seconds;

use Queue::Backend::FailureReason;
use UKIRT::Sequence;
use UKIRT::SequenceError qw/ :try /;

use base qw/Queue::Entry/;

=head1 METHODS

The following sub-classed methods are provided:

=head2 Constructor

=over 4

=item B<new>

The sub-classed constructor is responsible for checking the second
argument to see whether it is already a C<UKIRT::Sequence> object or
if one needs to be created from a file name (if unblessed).

  $entry = new Queue::Entry::UKIRTSeq( $label, $filename);
  $entry = new Queue::Entry::UKIRTSeq( $label, $seq_object);

Once the filename has been converted into a C<UKIRT::Sequence> object
the constructor in the base class is called.

=cut

sub new {
  my ($self, $label, $thing) = @_;

  # Check to see if thing is an object
  my $entity;
  if (UNIVERSAL::isa($thing, 'UKIRT::Sequence')) {
    # looks okay
    $entity = $thing;
  } elsif (not ref($thing)) {
    # treat it as a filename
    $entity = new UKIRT::Sequence( File => $thing );
  } else {
    croak "Argument to constructor is neither a UKIRT::Sequence object nor a simple scalar filename";
  }

  return $self->SUPER::new($label, $entity);
}

=back

=head2 Accessor methods

=over 4

=item B<entity>

This method stores or retrieves the C<UKIRT::Sequence> object associated with
the entry.

  $seq = $entry->entity;
  $entry->entity($seq);

=cut

sub entity {
  my $self = shift;

  if (@_) {
    my $seq = shift;
    croak 'Queue::Entry::UKIRTSeq::entity: argument is not a UKIRT::Sequence'
      unless UNIVERSAL::isa($seq, 'UKIRT::Sequence');
    $self->SUPER::entity($seq);
  }
  return $self->SUPER::entity;
}

=item B<instrument>

String describing the instrument associated with this queue entry.

  $inst = $e->instrument();

Delegated to the C<UKIRT::Sequence> C<getInstrument> method.

=cut

sub instrument {
  my $self = shift;
  my $entity = $self->entity;
  return "UNKNOWN" unless defined $entity;
  return $entity->getInstrument;
}

=item B<telescope>

String describing the telescope associated with this queue entry.
This is simply used for sanity checking the Queue Entry XML and
returns "UKIRT" in this case.

 $tel = $e->telescope();

=cut

sub telescope {
  return "UKIRT";
}

=back

=head2 Configuration

=over 4

=item B<configure>

Configures the object. This mainly involves checking that the second
argument is a C<UKIRT::Sequence> object. The first argument is the entry
label. This method must take two arguments.  There are no return
arguments.

  $entry->configure($label, $seq);

=cut

sub configure {
  my $self = shift;
  croak 'Usage: configure(label,UKIRT::Sequence)' if scalar(@_) != 2;
  croak unless UNIVERSAL::isa($_[1], "UKIRT::Sequence");
  $self->SUPER::configure(@_);
}

=item B<write_entry>

Write the entry to disk. In this case uses the C<writeseq> method from
C<UKIRT::Sequence>. Returns the names of all the files that were
created.  The first file in the returned list is the "primary" file
that can be used to create a new C<Queue::Entry> object of this class.

  @files = $e->write_entry();

By default, uses the directory from which the sequence was read.  An
optional argument can be used to specify a new output directory
(useful when dumping the queue contents to a temporary location via
XML (see L<Queue::EntryXMLIO/"writeXML">).

 @files = $e->write_entry( $outputdir );

An empty return list indicates an error occurred.

No attempt is made to "fixup" or "verify" the entry prior to writing.

If the config has not been modified the original filename will
be returned and the directory argument will be ignored.

=cut

sub write_entry {
  my $self = shift;
  my $dir = shift;

  # Get the sequence itself
  my $seq = $self->entity;
  return () unless defined $seq;

  my @files;
  if ($seq->modified) {
    # Configure the output directory
    my $out = $dir || $seq->inputdir();
    @files = $seq->writeseq( $out );
  } else {
    @files = ($seq->inputfile);
  }
  return @files;
}

=item B<prepare>

This method should be used to prepare the entry for sending to the
backend (in this case the UKIRT instrument task). It does two things:

=over 4

=item 1

Writes the sequence to disk in the form of a UKIRT sequence and
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

=cut

sub prepare {
  my $self = shift;
  my $info = shift || {};

  my $seq = $self->entity;

  # Should return a reason here
  return unless defined $seq;

  # Set miscellaneous header information.
  $seq->shift_type($info->{'shift_type'}) if defined $info->{'shift_type'};

  # Now verify that the sequence is okay and catch the exception
  # We do a fixup and a verify here. Note that fixup tries to correct
  # stuff that can be fixed without asking for more information
  my $r;
  try {
    $seq->fixup;
    $seq->verify;
  } catch UKIRT::SequenceError::MissingTarget with {
    # if the target is missing we cannot send this sequence
    # so we need to package up the relevant information
    # and pass it higher up
    # The information we need from the sequence is just
    #    MODE
    #    WAVEBAND
    $r = new Queue::Backend::FailureReason( 'MissingTarget',
					    MODE => 'Unknown',
					    # this returns a string in scalar
					    # context
					    WAVEBAND => $seq->getWaveBand,
					    INSTRUMENT => $self->instrument,
					    TELESCOPE => $self->telescope,
					  );
  } catch UKIRT::SequenceError with {
    # all other sequence errors can be dealt with via a fixup [maybe]
    $seq->fixup;

    # Just in case that did not work
    $seq->verify;

  } otherwise {
    # strange other error that we need to forward
    my $E = shift;
    $E->throw;
  };

  # if we ended up with a failure object we need to return it here
  return $r if $r;

  # Write the sequence
  my @files = $self->write_entry();
  return unless @files;

  # Store the filename in the be_object
  $self->be_object( $files[0] );

  return;
}

=item B<getTarget>

Retrieve target information from the entry in the form of an C<Astro::Coords>
object. Returns C<undef> if no target information is found.

 $c = $e->getTarget;

=cut

sub getTarget {
  my $self = shift;
  return $self->entity->getTarget;
}

=item B<setTarget>

Set target information associated with the entry. Requires an C<Astro::Coords>
object.

  $e->setTarget( $coords );

=cut

sub setTarget {
  my $self = shift;
  my $coords = shift;
  $self->entity->setTarget($coords);
}

=item B<clearTarget>

Clear target information associated with the entry.

  $e->clearTarget();

=cut

sub clearTarget {
  my $self = shift;
  $self->entity->clearTarget;
}

=item B<projectid>

Returns the project ID associated with this entry.

  $proj = $entry->projectid;

The base class always returns undef.

=cut

sub projectid {
  my $self = shift;
  return $self->entity->getProjectid;
}

=item B<msbid>

Returns the MSB ID associated with this entry.

  $msbid = $entry->msbid;

=cut

sub msbid {
  my $self = shift;
  return $self->entity->getMSBID;
}

=item B<msbtitle>

Return the MSB title assicated with this entry.

  my $msbtitle = $entry->msbtitle();

=cut

sub msbtitle {
  my $self = shift;
  return $self->entity()->getMSBTitle();
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
  my $seq = $self->entity;
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
		 $project,$posn,$seq->summary, $minutes);
}

=back

=head2 Destructors

The destructor removes the temporary file created by the
prepare() method (and stored in be_object()). The assumption
is that the file is no longer needed once it has been sent 
to the backend (the TODD).

Note that if C<write_entry> creates more than one output file
only the primary file will be deleted by the desctructor. This
is probably a bug and the system should be storing the file
names independently of the C<be_object> method.

Will not be used until UKIRT::Sequence actually starts writing
files.

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

L<Queue::Entry>, L<Queue::Contents>, L<UKIRT::Sequence>

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
