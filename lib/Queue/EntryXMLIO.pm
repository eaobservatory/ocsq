package Queue::EntryXMLIO;

=head1 NAME

Queue::EntryXMLIO - Read and write entries to disk using the Queue Entry XML

=head1 SYNOPSIS

    use Queue::EntryXMLIO;

    @entries = readXML($file);

    $file = writeXML(@entries);
    $file = writeXML({outputdir => "/tmp"}, @entries);

=head1 DESCRIPTION

Functions for reading and writing Queue entries from/to disk using
the telescope-independent XML transport format.

These functions are loosely bound to the rest of the queue system
to make it easier to use the functions in external systems (e.g.
the OMP) and to limit the dependencies of the queue system on
an XML parser [although since the queue currently loads OMP classes
to communicate with the database server this may be a moot point].

These functions could be methods associated with a collection of entry
objects but the current class hierarchy would suggest that it could
usefully be used by both the C<Queue::Contents> and C<Queue::MSB> classes.
(e.g. to dump the contents of a queue to disk).

If these functions are to be used to write anything more complicated
than a single translated MSB (e.g. a whole queue) then the XML will
have to be extended so that the MSB boundaries are delineated and the
MSB associations can be reconstructed. See L<"Possible Extensions">

=cut

use strict;
use warnings;
use Carp;
use XML::LibXML;
use File::Spec;
use Time::HiRes qw/gettimeofday/;

use Queue::Entry;  # To make sure we have the right search path

use vars qw/$VERSION $DEBUG @EXPORT_OK/;
use base qw/Exporter/;
$VERSION = '0.01';
$DEBUG = 0;

# Optional export list
@EXPORT_OK = qw/readXML writeXML/;

# Element and attribute names used in the XML
my $RE = "QueueEntries";        # Root element
my $EE = "Entry";               # Entry element
my $TA = "telescope";           # Telescope Attribute
my $DA = "totalDuration";       # Duration attribute
my $IA = "instrument";          # Instrument attribute


=head1 FUNCTIONS

These functions are not exported by default.

=over 4

=item B<readXML>

Read the specified XML file, parse it and convert the contents of the
file to an array of C<Queue::Entry> objects of the correct type.

    (@entries) = readXML($file);

The telescope name can be obtained from the entries themselves. The
file parsing does verify that the telescope specified in the XML matches
that expected from the entry objects.

If the global DEBUG flag is set to true, informational messages are
sent to STDOUT.

=cut

sub readXML {
    my $file = shift;

    # Now convert XML to parse tree
    my $parser = new XML::LibXML;
    my $doc = $parser->parse_file($file);

    # Find the root node
    my ($root) = $doc->findnodes(".//$RE");
    croak "Unable to locate root node $RE in file $file"
        unless defined $root;

    # Get the telescope
    my $tel = $root->getAttribute($TA);
    croak "Unable to find a telescope specified in the file $file"
        unless defined $tel;
    $tel = uc($tel);
    # $self->telescope( $tel );
    print "Telescope: $tel\n" if $DEBUG;

    # Loop over the individual entries
    my $counter = 0;
    my @entries;
    for my $e ($root->getChildrenByTagName($EE)) {
        my $time = $e->getAttribute($DA);
        my $inst = $e->getAttribute($IA);
        print "\tTime: $time Instrument : $inst\n" if $DEBUG;

        # Assume there is only a single child with no additional sub elements
        my $c = $e->firstChild;
        next unless defined $c;

        if (! $c->isa("XML::LibXML::Text")) {
            warn "Error parsing XML file $file. Filename not a text node.";
            next;
        }
        my $loc = $c->toString;

        # tidy up whitespace
        $loc =~ s/^\s+//;
        $loc =~ s/\s+$//;
        print "\tFile: $loc\n" if $DEBUG;

        # We should now create an entry object. The class of this object
        # should be of type Queue::Entry but subclass defined by the
        # telescope and instrument. Since all UKIRT entries are actually
        # of the same class but JCMT entry types depend on the instrument
        # we can either put logic in here that takes that into account
        # or create some empty Queue::Entry subclasses that map to the
        # instrument/telescope combination.
        # e.g Queue::Entry::JCMT_SCUBA, Queue::Entry::UKIRT_UIST
        # when all we really need is Queue::Entry::SCUBA and Queue::Entry::UKIRT.
        my $class = "Queue::Entry";
        if ($tel eq 'UKIRT') {
            $class .= "::UKIRTSeq";
        }
        elsif ($tel eq 'JCMT') {
            $class .= "::OCSCfgXML";
        }
        else {
            croak "Unrecognized telescope $tel";
        }

        # Now attempt to require the class
        print "Loading class $class\n" if $DEBUG;
        eval "require $class;";
        croak $@ if $@;

        # Increment the label counter and create a new queue entry object
        $counter ++;
        my $entry = new $class("Ent$counter", $loc);

        # Force the duration
        $entry->duration($time);

        # Verify the telescope
        my $t = $entry->telescope;
        croak "Telescope mismatch at entry $counter ['$tel' vs '$t']"
            unless $tel eq $t;

        # Store it
        push(@entries, $entry);
    }

    return (@entries);
}

=item B<writeXML>

Write the supplied entries to disk, using the supplied options.

    $file = writeXML(\%options, @entries);
    $file = writeXML(@entries);

The following keys are supported in the options hash:

=over 4

=item outputdir

Output directory for all entries and [if written]
the XML. Default is to use the output directory
as specified internally by each object, else
the current directory.

=item xmldir

Directory to which the Queue XML file is written.
Defaults to "outputdir" if specified, else current
directory.

=item noxmlfile

If true the entries will be written to disk but
the XML will be returned as a string rather than
writing to disk. Default is false.

=item fprefix

Prefix string to use for the output Queue entry
XML file. Defautls to "qentries".

=item chmod

Permissions mode to write the output files

=back

If written, the output file name for the XML is returned and includes
the full path.

The telescope is retrieved from the entry objects. An exception is
thrown if the telescope is not the same for each entry.

If debugging is enabled the XML is printed to the default filehandle.

Note that the entry objects supplied to this method do not have to
be C<Queue::Entry> objects. They just need to implement the following
methods identically to the C<Queue::Entry> class:

=over 4

=item *

telescope

=item *

duration

=item *

instrument

=item *

write_entry or write_file

=back

This would allow the OMP translators to call this function
using only a lightweight wrapper.

=cut

sub writeXML {
    my %options = (
        noxmlfile => 0,
        fprefix => "qentries",
    );

    # See if the first argument is a hash reference
    if (ref($_[0]) eq 'HASH') {
        my $href = shift;
        # merge options with defaults
        %options = (%options, %$href);
    }

    # override output directory
    my $outputdir;
    $outputdir = $options{outputdir} if exists $options{outputdir};

    # XML output directory
    my $xmldir;
    if (exists $options{xmldir}) {
        $xmldir = $options{xmldir};
    }
    elsif (exists $options{outputdir}) {
        $xmldir = $options{outputdir};
    }
    else {
        $xmldir = File::Spec->curdir;
    }

    # Read all the entries
    my @entries = @_;

    croak "No entries supplied" unless @entries;

    # Check attributes
    for my $e (@entries) {
        for my $method (qw/ telescope instrument duration /) {
            croak("Entry of class '" . ref($e)
                    . "' can not support the '$method' method")
                unless $e->can($method);
        }
    }

    # Retrieve the telescope name and verify that it is the same
    # for each entry
    my $tel = uc($entries[0]->telescope);
    my $counter = 0;
    for my $e (@entries) {
        $counter ++;
        my $t = uc($e->telescope);
        croak "Telescope mismatch in entries ['$tel' vs '$t'], starting at entry $counter"
            if $tel ne $t;
        croak "Telescope must be filled in for an entry (entry $counter)."
            . " Possible programming error.\n"
            unless $t;
    }

    # Build up the XML in memory first before writing it to disk
    my $xml = '<?xml version="1.0" encoding="ISO-8859-1"?>' . "\n"
        . "<$RE $TA=\"$tel\">\n";

    # Options for file output
    my %fileopt;
    $fileopt{chmod} = $options{chmod} if exists $options{chmod};

    # Ask each entry to write itself to the output directory
    # returning the relevant file name.
    for my $e (@entries) {
        # Directory to use for this particular entry. Depends on whether
        # we had an override defined
        my $thisdir;

        # see if we have an output directory for this entry
        if (defined $outputdir) {
            # we must override
            $thisdir = $outputdir;
        }
        elsif ($e->can('outputdir')) {
            # we have an output dir method and no specified override
            if (defined $e->outputdir) {
                $thisdir = $e->outputdir;
            }
            else {
                $thisdir = File::Spec->curdir;
            }
        }
        else {
            # current direcotry
            $thisdir = File::Spec->curdir;
        }

        # Write
        my @files;
        if ($e->can("write_entry")) {
            @files = $e->write_entry($thisdir, \%fileopt);
        }
        elsif ($e->can("write_file")) {
            @files = $e->write_file($thisdir, \%fileopt);
        }
        else {
            croak "Do not know how to write entry of class '" . ref($e) . "' to disk";
        }
        my $duration = $e->duration->seconds;
        my $inst = $e->instrument;

        # specify a full path to the file
        my $abs = File::Spec->rel2abs($files[0]);

        $xml .= "  <$EE $DA=\"$duration\" instrument=\"$inst\">$abs</$EE>\n";
    }

    # Close the XML
    $xml .= "</$RE>\n";

    # if we have debugging enabled we should print the XML itself
    print $xml if $DEBUG;

    # now either write the XML to disk or return it
    if ($options{noxmlfile}) {
        print "Request to return XML string.\n" if $DEBUG;
        return $xml;
    }
    else {
        # Write the file to disk Rather than using integer seconds and
        # risking a clash (which may then also require us to build in a
        # loop. Use format qentries_seconds_ms.xml
        # Currently do not check that the file previously exists
        # Time::HiRes returns microseconds
        # so only need the first 3 digits
        my ($sec, $mic_sec) = gettimeofday();
        my $ms = substr($mic_sec, 0, 3);
        my $filename = File::Spec->catfile($xmldir,
            $options{fprefix} . "_$sec" . "_$ms.xml");
        print "Writing XML File: $filename\n" if $DEBUG;

        open my $fh, ">$filename"
            or croak "Error writing XML file:$filename - $!";
        print $fh $xml;
        close($fh) or croak "Error closing XML file: $filename - $!";

        chmod $options{chmod}, $filename
            if exists $options{chmod};

        return $filename;
    }
}

1;

__END__

=back

=head1 GLOBAL VARIABLES

The following global variables can be modified:

=over 4

=item B<$DEBUG>

Controls whether debug messages are sent to STDOUT as the parse
progresses. Default is false.

=back

=head1 XML FORMAT

The XML format used for queue I/O is intended to be simple. The root
element is C<QueueEntries> (which also specifies the telescope name as
a sanity check) and each queue entry is contained within that root
element using a C<Entry> element.

    <?xml version="1.0" encoding="ISO-8859-1"?>
    <QueueEntries telescope="JCMT">
        <Entry totalDuration="456" instrument="ACSIS">conf.xml</Entry>
    </QueueEntries>

Note that the estimated duration of the observation is provided as an
attributeto the C<Entry>, units are always seconds, as is the
instrument name.  Currently the content of the observation to be
queued is specified as a filename. The instrument type is used to
determine what class C<Queue::Entry> object should be instantiated.
Usually the filename includes the full path to the file to avoid
any confusion over current working directory.

It is possible that the C<Entry> could be extended to include the
actual contents of the queued observation rather than a reference to
an external file. This is not yet implemented.

=head2 Possible Extensions

In principle this XML format could be extended to allow the entire
contents of the queue to be saved and restored (or a subset). For this
to be possible additional information must be specified to indicate
which entries are part of the same MSB (technically "were loaded to
the queue at the same time" since a single MSB can be on the queue
multiple times) and which entries are calibrations not associated with
an MSB but which may be within an MSB. For example:

    <QueueEntries>
        <MSB msbid="04af">
            <Entry status="OBSERVED">...</Entry>
            <Entry status="OBSERVED">...</Entry>
            <Entry status="QUEUED" cal="1">...</Entry>
            <Entry status="QUEUED">...</Entry>
        </MSB>
        <Entry cal="1" status="QUEUED">...</Entry>
        <MSB msbid="ff32">
            ...
        </MSB>
    </QueueEntries>

Where we add a new C<MSB> element to group related observations (the
MSB ID may not be necessary since that is, currently, always in the
underlying file) and also add two new attributes to the C<Entry>
elements. "status" is identical to the status string returned by the
C<Queue::Entry> C<status> method [although "SENT" should be replaced
with "QUEUED"] and "cal" indicates whether the entry is part of the
MSB or simple a calibration inserted into the middle. Note that in
this proposal all entries associated with an MSB should be inside an
MSB element, any entries not enclosed by an MSB element should be
marked as calibrations. This implies that the proposed form of XML is
not backwards compatible with the current form.

=head1 AUTHOR

Tim Jenness E<lt>t.jenness@jach.hawaii.eduE<gt>.

Copyright (C) 2003-2004 Particle Physics and Astronomy Research Council.
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
