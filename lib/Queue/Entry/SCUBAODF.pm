package Queue::Entry::SCUBAODF;

=head1 NAME

Queue::Entry::SCUBAODF - Queue entry for ODF files treated as a hash

=head1 SYNOPSIS

  use Queue::Entry;

  $entry = new Queue::Entry::SCUBAODF('name',\%odf);

  $entry->label($label);
  $entry->configure('label',\%odf);
  $entry->entity(\%odf);
  $text = $entry->string;
  $entry->prepare;

=head1 DESCRIPTION

This class describes entries that can be manipulated by a
Queue::Contents class. The particular type of entry must be a
C<SCUBA::ODF> object.  that is converted to a file. The string
representation of the entry is obtained directly from the
C<SCUBA::ODF> object.

This class is a sub-class of Queue::Entry.

It is a thin layer on top of a C<SCUBA::ODF> object.

=cut

use 5.006;
use warnings;
use strict;
use Carp;
use SCUBA::ODFError qw/ :try /;
use Queue::Backend::FailureReason;
use File::Basename;

use base qw/Queue::Entry/;

# output directory for ODFs so that scuba can see them
# These should be read from a config file
our $TRANS_DIR = "/observe/ompodf";
our $VAX_TRANS_DIR = "OBSERVE:[OMPODF]";

=head1 METHODS

The following sub-classed methods are provided:


=head2 Accessor methods

=over 4

=item entity

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

=back

=head2 Configuration

=over 4

=item configure

Configures the object. This mainly involves checking that the second
argument is a C<SCUBA::ODF> object. The first argument is the entry
label. This method must take two arguments.  There are no return
arguments.

  $entry->configure($label, $odf);

=cut

sub configure {
  my $self = shift;
  croak 'Usage: configure(label,SCUBA::ODF)' if scalar(@_) != 2;
  $self->SUPER::configure(@_);
}

=item prepare

This method should be used to prepare the entry for sending to the
backend (in this case the SCUCD task). It does two things:

=over 4

=item 1

Writes the ODF to disk in the form of an ODF file. See the
C<SCUBA::ODF> C<writeodf> for more information on how this
works.

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
  my $r;
  try {
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
					       FILTER => $odf->odf->{FILTER},
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
  # Should really specify the output directory here!
  # to make sure it goes to tthe correct place
  $odf->outputdir( $TRANS_DIR );
  $odf->vax_outputdir( $VAX_TRANS_DIR );
  my $file = $odf->writeodf();

  # kluge until I can get umask working
  # Makes sure the files are readable by the vax
  chmod 0666, $file;

  # Store the filename in the be_object
  # SCUBA must get  a full path to the file using vax syntax
  $self->be_object($VAX_TRANS_DIR . basename($file));

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
  return $odf->summary();
}

=back

=head2 Destructors

The destructor removes the temporary file created by the
prepare() method (and stored in be_object()). The assumption
is that the file is no longer needed once it has been sent 
to the backend (the TODD).

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

Copyright (C) Particle Physics and Astronomy Research Council.
All Rights Reserved.

=cut
