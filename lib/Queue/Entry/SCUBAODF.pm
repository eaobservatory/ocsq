package Queue::Entry::SCUBAODF;

=head1 NAME

Queue::Entry::SCUBAODF - Queue entry for ODF files treated as a hash

=head1 SYNOPSIS

  use Queue::Entry::SCUBAODF;

  $entry = new Queue::Entry::SCUBAODF('name', $odf_object );
  $entry = new Queue::Entry::SCUBAODF('name', $file );

  $entry->label($label);
  $entry->configure('label',$odf_object);
  $entry->entity($odf_object);
  $text = $entry->string;
  $entry->prepare;

=head1 DESCRIPTION

This class describes entries that can be manipulated by a
Queue::Contents class. The particular type of entry must be a
C<SCUBA::ODF> object.  This object is converted to a file on disk when
the entry is sent to the backend (the JCMT instrument task or SCUCD
itself). The string representation of the entry is obtained directly
from the C<SCUBA::ODF> object.

This class is a sub-class of C<Queue::Entry>

It is a thin layer on top of a C<SCUBA::ODF> object.

=cut

use 5.006;
use warnings;
use strict;
use Carp;
use Time::Seconds;
use File::Basename;

use SCUBA::ODF;
use SCUBA::ODFError qw/ :try /;
use Queue::Backend::FailureReason;

use base qw/Queue::Entry/;

# The VAX variant of the outputdir. Probably need to read it from
# a config file.
our $VAX_TRANS_DIR = "OBSERVE:[OMPODF]";

=head1 METHODS

The following sub-classed methods are provided:

=head2 Constructor

=over 4

=item B<new>

The sub-classed constructor is responsible for checking the second
argument to see whether it is already a C<SCUBA::ODF> object or if one
needs to be created from a file name (if unblessed).

  $entry = new Queue::Entry::SCUBAODF( $label, $filename);
  $entry = new Queue::Entry::SCUBAODF( $label, $odf_object);

Once the filename has been converted into a C<SCUBA::ODF> object
the constructor in the base class is called.

=cut

sub new {
  my ($self, $label, $thing) = @_;

  # Check to see if thing is an object
  my $entity;
  if (UNIVERSAL::isa($thing, 'SCUBA::ODF')) {
    # looks okay
    $entity = $thing;
  } elsif (not ref($thing)) {
    # treat it as a filename
    $entity = new SCUBA::ODF( File => $thing );
  } else {
    croak "Argument to constructor is neither a SCUBA::ODF object nor a simple scalar filename";
  }

  return $self->SUPER::new($label, $entity);
}

=back

=head2 Accessor methods

=over 4

=item B<entity>

This method stores or retrieves the C<SCUBA::ODF> object associated with
the entry.

  $odf = $entry->entity;
  $entry->entity($odf);

=cut

sub entity {
  my $self = shift;

  if (@_) {
    my $odf = shift;
    croak 'Queue::Entry::SCUBAODF::entity: argument is not a SCUBA::ODF'
      unless UNIVERSAL::isa($odf, 'SCUBA::ODF');
    $self->SUPER::entity($odf);
  }
  return $self->SUPER::entity;
}

=item B<instrument>

String describing the instrument associated with this queue entry.

  $inst = $e->instrument();

Returns the string "SCUBA".

=cut

sub instrument {
  return "SCUBA";
}

=item B<telescope>

String describing the telescope associated with this queue entry.
This is simply used for sanity checking the Queue Entry XML and
returns "JCMT" in this case.

 $tel = $e->telescope();

=cut

sub telescope {
  return "JCMT";
}

=back

=head2 Configuration

=over 4

=item B<configure>

Configures the object. This mainly involves checking that the second
argument is a C<SCUBA::ODF> object. The first argument is the entry
label. This method must take two arguments.  There are no return
arguments.

  $entry->configure($label, $odf);

=cut

sub configure {
  my $self = shift;
  croak 'Usage: configure(label,SCUBA::ODF)' if scalar(@_) != 2;
  croak unless UNIVERSAL::isa($_[1], "SCUBA::ODF");
  $self->SUPER::configure(@_);
}

=item B<write_entry>

Write the entry to disk. In this case uses the C<writeodf> method
from C<SCUBA::ODF>. Returns the names of all the files that were created.
The first file in the returned list is the "primary" file that can
be used to create a new C<Queue::Entry> object of this class.

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
  my $odf = $self->entity;
  return () unless defined $odf;

  # Configure the output directory
  my $out = $dir || $self->outputdir;
  $odf->outputdir( $out );
  $odf->vax_outputdir( $VAX_TRANS_DIR );
  my $file = $odf->writeodf();

  # kluge until I can get umask working
  # Makes sure the files are readable by the vax
  chmod 0666, $file;

  # including things like WPLATE file
  # and the related vax files
  my %files = %{$odf->vaxfiles};
  chmod 0666, values %files if values %files;

  # Return the filenames
  return ($file, values %files);

}

=item B<prepare>

This method should be used to prepare the entry for sending to the
backend (in this case the SCUCD task). It does two things:

=over 4

=item 1

Writes the ODF to disk in the form of an ODF file. See the
C<write_entry> method.

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

  my $odf = $self->entity;

  # Should return a reason here
  return unless defined $odf;

  # Now verify that the ODF is okay and catch the exception
  # We do a fixup and a verify here. Note that fixup tries to correct
  # stuff that can be fixed without asking for more information
  my $r;
  try {
    $odf->fixup;
    $odf->verify;
  } catch SCUBA::ODFError::MissingTarget with {
    # if the target is missing we cannot send this ODF
    # so we need to package up the relevant information
    # and pass it higher up
    # The information we need from the ODF is just
    #    MODE
    #    FILTER
    $r = new Queue::Backend::FailureReason( 'MissingTarget',
					    MODE => $odf->odf->{OBSERVING_MODE},
					    WAVEBAND => $odf->odf->{FILTER},
					    INSTRUMENT => $self->instrument,
					    TELESCOPE => $self->telescope,
					     );
  } catch SCUBA::ODFError with {
    # all other SCUBA errors can be dealt with via a
    # fixup
    $odf->fixup;

    # Just in case that did not work
    $odf->verify;

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

  # Store the filename in the be_object
  # SCUBA must get  a full path to the file using vax syntax
  $self->be_object($VAX_TRANS_DIR . basename($files[0]));

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

=back

=head2 Display methods

=over 4

=item B<string>

Control how the entry is displayed in the queue summary.

 $string = $entry->string;

=cut

sub string {
  my $self = shift;
  my $odf = $self->entity;
  my $posn = $self->msb_status;
  my $project = $self->projectid;
  $project = "NONE" unless defined $project;
  $project = substr($project, 0, 10);
  return sprintf("%-10s%-10s%-14s%s",$self->status,
		 $project,$posn,$odf->summary);
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

=cut

sub DESTROY {
  my $self = shift;

  my $file = $self->be_object;

  if (defined $file) {
#    print "UNLINK $file\n" if -e $file;
    unlink $file if -e $file;
  }
}


1;

=head1 SEE ALSO

L<Queue::Entry>, L<Queue::Contents>, L<SCUBA::ODF>

=head1 AUTHOR

Tim Jenness E<lt>t.jenness@jach.hawaii.eduE<gt>

Copyright (C) 1999-2004 Particle Physics and Astronomy Research Council.
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
