package Queue::Control::DRAMA;

=head1 NAME

Queue::Control::DRAMA - provides subroutines for controlling the DRAMA
                        based queue

=head1 SYNOPSIS

  use Queue::Control::DRAMA;

  stopq;
  exitq;
  clearq;
  startq;

  addback @odfs;
  addback @odfs,"source=mars";
  addfront "test.m","sou=uranus","cat=m96bu40.cat";
  addfront @odfs, { source => 'mars' };

  cutq 4,2;
  pasteq 2;
  pasteq 3,@odfs;

=head1 DESCRIPTION

This module provides subroutines for controlling the DRAMA based queue.
Routines are provided for adding ODFs to the queue, stopping, starting
and clearing the queue and cutting and pasting queue entries.

To avoid the queue having to know which directory an ODF is in,
the entire ODF (or more than one) are converted to an SDS data 
structure and sent directly to the queue.

=head1 OBSERVATION DEFINITON FILES

The routines assume that Observation Definition Files (ODF) 
are used. An ODF consists of lines containing keywords and
values, eg:

  CATALOG point.cat
  SOURCE  mars

A different interface would be required if ODF
files are not used (eg if XML files are to be used).

An additional feature concerns the override of ODF parameters
by the caller. An array of 'keyword=value' pairs or a
reference to a hash can be supplied to routines in addition
to ODF names. 
The addback(), addfront() and pasteq() routines allow parameter
overrides when supplying ODF files. For example:

  addback "test.odf", "source=mars", "point=my.cat";

would read the odf files "test.odf" and change the 'source' and
'point' values to 'mars' and 'my.cat' respecitvely. The routines
distinguish ODF names from parameter overrides by looking for
the presence of an equals sign. Additionally, a reference
to a hash can be supplied:

  addfront "test.odf", { source => 'mars', point => 'my.cat'};

would add the ODF 'test.odf' to the front of the queue overriding
'source' and 'point' as before.

  addfront "test.odf", "s=mars", "p=my.cat";

would also have the same behaviour if a list of valid parameters
had been assigned specifying that 'SOURCE' and 'POINT' can be
determined using minimum matching.

In order for overrides to work the variable
$Queue::Control::DRAMA::DEFAULTS must be set so that it
contains a reference to a hash where the keys are the 
allowed keys (upper-cased). Only keys found in this hash
can be overridden. Any other keys will be ignored.

Warning: if a user-supplied override  minimum matches two or more
parameters the any could be overridden.

All ODF keywords are converted to upper-case before being sent
to the queue. Keywords in ODFs are not minimum matched.

=head1 GLOBAL VARIABLES

The following variables must be set before using the routines.
They are all in the Queue::Control::DRAMA:: namespace:

 QUEUE - this is the name of the DRAMA Queue task.
 DEFAULTS - reference to a hash containing all the allowed
            keywords for minimum matching.

=cut

use strict;
use DRAMA;
use Exporter;
use PDL::Options;
#use Data::Dumper;
use IO::File;
use File::Basename;  # Split file name into dir and file
use Cwd;             # Get current directory

use Carp;
use base qw/ Exporter /;

use vars qw/@EXPORT $DEFAULTS $QUEUE $VERSION/;

$DEFAULTS = {};
@EXPORT = qw/ addback addfront pasteq clearq cutq stopq startq exitq /;

$VERSION = '0.10';

=head1 QUEUE CONTROL

The following routines are available for controlling the queue.

=over 4

=item startq

Start the queue. No arguments or return values.

=cut

sub startq {
  obeyw $QUEUE, 'STARTQ';
}

=item stopq

Stop the queue. No arguments or return values.

=cut


# STOPQ
sub stopq {
  obeyw $QUEUE, 'STOPQ';
}

=item exitq

Cause the queue task to exit.
No arguments or return values.

=cut


# EXIT the queue task
sub exitq {
  obeyw $QUEUE, 'EXIT';
}

=item clearq

Clear all entries in the queue (including the paste buffer)
No arguments or return values.

=cut


# CLEARQ
sub clearq {
  obeyw $QUEUE, 'CLEARQ';
}


=item cutq(position, number)

Cut entries from the queue and copy them to the paste buffer.
Two arguments are required:

  position - the position to start the cut (starts at position 1)
  number   - number of items to cut from the queue. 

=cut


# CUTQ
sub cutq {
  croak 'usage: cutq posn number' unless scalar(@_) == 2;
  my $posn = shift;

  croak "Supplied position is not an integer: $posn"
    unless $posn =~ /^\d+$/;

  my $ncut = shift;

  croak "Supplied cut is not an integer: $ncut"
    unless $ncut =~ /^\d+$/;

  my $arg = Arg->Create;
  my $status = new DRAMA::Status;
  $arg->Puti('POSN',$posn,$status);
  $arg->Puti('NCUT',$ncut,$status);

  # Send the obey
  obeyw($QUEUE,"CUTQ",$arg);
}



=item pasteq(position, ..odfs.. )

Paste entries from the paste buffer to the specified position.
If an ODF is specified, the ODF is placed at the desired
position and the paste buffer contents are not used.

Similar to the addback() and addfront() routines, multiple
ODFs can be specified as well as parameter overrides. See
the section on Observation Definition Files earlier in this
document.

  pasteq 5;   # Paste buffer contents to position 5
  pasteq 3, "test.odf"; # insert test.odf at position 3
  pasteq 3, "test.odf", "s=mars"; # insert at position 3 with override

=cut


# PASTEQ
sub pasteq {
  croak 'usage: pasteq posn [odfs]' unless scalar(@_) >= 1;
  my $posn = shift;

  croak "Supplied position is not an integer: $posn"
    unless $posn =~ /^\d+$/;

  my $arg; # The arguments

  # If we have some extra arguments we can assume they are
  # odf names
  if (@_) {
    my $odfhash = read_odfs(@_);
    $odfhash->{POSN} = $posn;
    $arg = Sds->PutHash($odfhash, 'Qcontrol',new DRAMA::Status);
  } else {
    $arg = Arg->Create;
    $arg->Puti('POSN', $posn, new DRAMA::Status);
  }

  # Send the obey
  obeyw $QUEUE, 'PASTEQ', $arg;
}


=item addback( ..odf.. )

Add supplied ODFs to the back of the queue.
Similar to the addfront() and pasteq() routines, multiple
ODFs can be specified as well as parameter overrides. See
the section on Observation Definition Files earlier in this
document.

  addback "test.odf";
  addback "test.odf", "s=mars";
  addback "test.odf", { s => 'mars' };

=cut

sub addback {
  add2queue('BACK',@_);
}


=item addfront( ..odf.. )

Add supplied ODFs to the front of the queue.
Similar to the addback() and pasteq() routines, multiple
ODFs can be specified as well as parameter overrides. See
the section on Observation Definition Files earlier in this
document.

  addfront "test.odf";
  addfront "test.odf", "s=mars";
  addfront "test.odf", { s => 'mars' };

=cut

sub addfront {
  add2queue('FRONT',@_);
}


# ADD odfs to queue
#   First argument specified FRONT or BACK of queue
#   At least one argument should be an odf name (can be more than 1)
#   Options of the form  keyword=value can be supplied to override
#   entries in the ODF. Minimum matching is supported (via PDL::Options).


sub add2queue {
  my $posn = shift;
  croak 'usage: addback [options] odf1 [odf2]'
    unless scalar(@_) > 0;

  my $odfs = read_odfs(@_);

  # Convert to Sds structure
  my $status = new DRAMA::Status;
  my $arg = Sds->PutHash($odfs, 'Qcontrol',$status);

  unless ($status->Ok) {
    $status->Flush;
    croak "Error constructing Sds argument - add2queue($posn)";
  }

  # $arg->List($status);

  # Send to the queue
  if ($posn eq 'FRONT') {
    obeyw($QUEUE,"ADDFRONT",$arg);
  } elsif ($posn eq 'BACK') {
    obeyw($QUEUE,"ADDBACK",$arg);
  } else {
    croak "Error - do not know how to add to position $posn of queue";
  }

}



=back


=head1 REQUIREMENTS

Requires the perl/DRAMA module. The DRAMA system must be initialised
before using these routines.

=head1 SEE ALSO

L<DRAMA>, L<Queue>

=head1 AUTHOR

Tim Jenness (t.jenness@jach.hawaii.edu)
(C) Copyright PPARC 1999.

=cut

####################################################################

# These are internal routines for actually reading ODFs and
# combining options. This may go in a separate package at some point

####################################################################

# Subroutine to convert an array of the form
#   key1=value  key2=value odf_name  odf_name2  key4=value etc...
# to a perl hash of the form
#    ODF1 => {   keys/values},
#    ODFn => {   keys/values} etc.
#  [this is because SDS can not handle an array of hashes]
# Can also use a hash reference in addition to key=value strings.
#  Returns a hash ref (or die on error)

sub read_odfs {
  my @args = @_;

  # Check for odf keyword overrides
  # of the form KEY=VALUE
  # Extract ODF names (ie those not containing  an equals sign
  my @options = ();
  my @odfs    = ();
  foreach my $opt (@_) {
    # If $opt has an equals or is a hash ref, store it in the
    # options
    if ($opt =~ /=/ || ref($opt) eq 'HASH') {
      push(@options, $opt);
    } else {
      push(@odfs, $opt);
    }
  }

  # print Dumper([\@odfs,\@options]);

  # complain if @odfs is empty
  croak 'Error - no ODF names supplied' unless @odfs;

  # Read the odfs into an hash
  # where the key is the actual odf file name
  my ($keyarr, $odfarr) = slurp_odfs(@odfs);

  croak 'Error reading these odfs: '. join(',',@odfs)
    unless @$odfarr;

  # Merge any options supplied on the command-line with
  # the odfs that have been read
  # Loop outside the subroutine for efficiency with Macros
  # (which are processed one at a time) even though this means
  # that the options are processed each time round this loop
  if (@options) {
    foreach my $odf (@$odfarr) {
      merge_options($odf, \@options, $DEFAULTS);
    }
  }

  # We now have an array of odfs, with user-supplied overrides
  # Now convert to hash rather than array
  my %final = ();
  for my $i (0..$#$odfarr) {
    $final{"ODF$i"} = { Label => $keyarr->[$i], 'ODF'=> $odfarr->[$i]};
  }

  return \%final;
}


# Subroutine to slurp odfs from disk and convert to hash.
# Returns an array with alternating odf filename and corresponding
# reference to hash containing the odf information. This can easily
# be converted to a hash later. Do it this way so that order information
# can be retained.
# Accepts an array of odf names as argument.
# Macros can be read containing lists of odf files.
# In the case of a macro, this routine would be called recursively.
# A macro is signified by a line containing the word MACRO.
# Any lines after this are assumed to refer to odf filenames
# This should probably be in a class.... (eg ObsDesk::OdfIO)
# Note that the keys are upper-cased.

sub slurp_odfs {
  my @files = @_;

  my @odfs = ();
  my @odfkeys = ();

  # Loop over filenames
  for my $file (@files) {
    chomp $file;

    # Split the string on space in case there are keyword 
    # overrides supplied
    ($file, my @options) = split(/\s+/,$file);
    next unless defined $file;

    my %odf = (); # This is the odf itself
    
    # Is file here?
    if (-e $file) {
      my $fh = new IO::File("< $file");
      if (defined $fh) {
      READ: while (defined(my $line = <$fh>)) {
	  # Remove leading and trailing space
	  chomp($line);
	  $line =~ s/^\s+//;
	  $line =~ s/\s+$//;

	  # Skip if starts with ! or #
	  next READ if $line =~ /^[!\#]/;

	  # If we have a macro slurp the rest of the file and
	  # exit the loop, calling this routine
	  if ($line =~ /MACRO/i) {
	    my @remainder = <$fh>;

	    # The files read in from a macro
	    # Should be referenced relative to the directory
	    # containing the macro.
	    # We therefore have to chdir to that directory
	    # and then escape back to our current directory afterwards
	    my $odfdir = dirname($file);

	    my $this_dir;
	    if ($odfdir ne '.') {
	      $this_dir = cwd;
	      chdir($odfdir) or 
		croak "Could not change to directory $odfdir: $!";
	    }

	    # Read the ODFS
	    my ($keyref,$macro) = slurp_odfs(@remainder);

	    # Change back to real directory
	    chdir($this_dir) if defined $this_dir;

	    # Copy the macro contents to the array containing
	    # the previously read ODFs
	    if (defined $macro) {
	      push(@odfs, @$macro);
	      push(@odfkeys, @$keyref);
	    }

	    # Exit the loop
	    last READ;
	  }
	  
	  # Split into 2 parts
	  my ($key, $value) = split(/\s+/,$line, 2);
	  next unless defined $key;
	  
	  # Store the value
	  $odf{uc($key)} = $value if defined $value;

	}

	if (%odf) {
	  # Store the hash reference if there are some keys defined
	  push(@odfs, \%odf);
	  push(@odfkeys, $file);
	}

	# Now loop over @odfs and apply any options that
	# might have been supplied for the macro or single odf
	if (@options) {
	  foreach (@odfs) {
	    # Apply any overrides specified from the macro
	    merge_options($_, \@options, $DEFAULTS ) if @options;
	  }
	}

      }
    }

  }

  return (\@odfkeys,\@odfs);
}


# Subroutine to merge options from an array of key=value strings
# with an existing hash. The following arguments are required:
#
#  Hash ref containing the ODF key/value pairs
#  Ref to an array containing strings of the form key=value.
#       these strings are converted to a hash in this routine
#       This array can also contain hash references which
#       are also allowed.
#  Ref to a hash containing the default keys (for minimum-matching)
#       the values supplied in this hash are not important
#
#  Returns nothing (the hash is modified in place).

sub merge_options {

  # print "MERGE: ".Dumper(\@_);

  # Check that we have 3 args
  croak 'Usage: merge_options(\%odfs, \@options, \%defaults)'
    unless (scalar(@_) == 3 &&
	    ref($_[0]) eq 'HASH' &&
	    ref($_[1]) eq 'ARRAY' &&
	    ref($_[2]) eq 'HASH'
	   );

  # read args
  my ($odfs, $options, $defaults) = @_;

  # Now we can try to merge our hashes with any supplied options
  if ($#$options > -1) {

    # convert array to an options hash (looking for any hash refs
    # as well)
    my %supplied = ();
    foreach (@$options) {
      if (/=/) {
	my ($key, $value) = split(/=/,$_);
	$supplied{uc($key)} = $value if defined $value;
      } elsif (ref($_) eq 'HASH') {
	%supplied = (%supplied, %$_);
      }
    }

    # Create the new PDL::Options object and configure it
    my $pdlopt = new PDL::Options;
    $pdlopt->full_options(0);  # Only want supplied options, not defaults
    $pdlopt->defaults($defaults);
    
    # Retrieve expanded options
    my $expanded = $pdlopt->options(\%supplied);

    # Now loop over the odf files and insert the user-supplied
    # overrides
    %$odfs = (%$odfs, %$expanded);

#    foreach my $odf (keys %$odfs) {
#      %{$odfs->{$odf}} = (%{$odfs->{$odf}}, %{$expanded});
#    }

  }
}


1;
