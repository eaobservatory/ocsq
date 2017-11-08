package Queue::Server::DRAMA;

=head1 NAME

Queue::Server::DRAMA - Implementation of a queue server task using DRAMA

=head1 SYNOPSIS

  use Queue::Server::DRAMA;

  $Q = new Queue::Server::DRAMA( nentries => 250, simdb => 1 );
  $Q->mainloop();

=head1 DESCRIPTION

DRAMA code required to implement basic DRAMA-based queue as a DRAMA
task.

Things that need to be tidied up:

  - QUEUEID [currently shared lexical]
      + Should really be determined by the queue object when
        entries are pushed onto the queue.
  - What to do about MSBTidy
      + It calls an update_param function so clearly needs to know
        about drama. Everything else is actually generic and could go
        in a base class but that won't work because we are passing around
        just the code ref.
  - Do we put the callbacks in their own package?
    They could be called using   POLL => sub { $self->POLL( @_ )}
    if we wanted to do it "properly"

Also,

  - MSBCOMPLETE stuff could be done using a new class and a has-a
    relationship.

I don't think we can associate this object directly with the callbacks
at this time.

=cut

use strict;
use warnings;
use Carp;
use Queue::JitDRAMA;
use Queue::Constants;
use Term::ANSIColor qw/ colored /;
use Data::Dumper;
use Storable qw/ nstore retrieve /;

use Queue::MSB;
use Queue::EntryXMLIO qw/ readXML /;

use JAC::OCS::Config::TCS;

use OMP::Config;
use OMP::MSBServer;
use OMP::Info::Comment;
use OMP::Error qw/ :try /;

use vars qw/ $VERSION /;
$VERSION = '0.01';

# Default parameters
# These control the number of entries in the DRAMA parameter
# and the length of each line.
# Should be using SdsResize to deal with this constraint
use constant NENTRIES => 200;
use constant MAXWIDTH => 110;

# Default name of the queue task
use constant TASKNAME => 'OCSQUEUE';

# Set maxreplies
$DRAMA::MAXREPLIES = 40;

# Singleton object
my $Q;

=head1 INITIALISATION

Initialisation routines.

=over 4

=item B<new>

Instantiated a DRAMA-based queue task.

  $Q = new Queue::Server::DRAMA( simdb => $sim, 
                                 taskname => 'OCSQUEUE',
                                 nentries => 52,
                                 maxwidth => 132,
                                );

The following [case-insensitive] options are supported:

=over 8

=item simdb

Run the queue in database simulation mode such that the queue never
prompts the user to officially accept, reject or suspend an MSB. Default
is false. Note that the MSB completion parameter will still be populated and
the queue monitor will still request input from the user to clear the MSB
(even though the clear will be immediate and will not talk to the database).
See the C<nocomplete> parameter to disable the MSB acceptance behaviour completely.
Note that this flag will effectively be automatically enabled if C<nocomplete>
is set since the code to process accepts will never be activated.

=item nocomplete

Do not store MSB completion parameters in the parameter system. Simply
log the fact we would have completed an MSB. This allows the queue to
run without forcing the user to deal with MSBs. During engineering tests
it is usually annoying for a MSB accept popup to appear only for the observer
to click on "Took No Data". This will disable the queue monitor popup.

=item taskname

Name of the task as it would appear to the DRAMA messaging system.
Can not be changed after object instantiation. Defaults to OCSQUEUE

=item nentries

Number of entries present in the queue. Technically this refers to the
number of entries visible to the DRAMA parameter system and not the
internal perl queue. Can not currently be changed after object
instantiation. Defaults to 200.

=item maxwidth

Maximum width of the string form of each individual entry in the queue.
Technically this refers to the size of each text item in the DRAMA parameter
system and not the size in the corresponding perl Queue. Can not currently
be changed after object instantiation. Defaults to 110.

=item polltime

Time (in integer seconds) between polls to the queue backend. Defaults
to 1 second.

=item verbose

Turn on verbose debug messages. Default is false.

=back

Implemented as a singleton. The same object is returned regardless
of the number of times this method is invoked.

Automatically initialises the application as a DRAMA task and
creates the parameter system. The queue will not start running until
the init_loop() method is invoked.

=cut

sub new {
  my $proto = shift;
  my $class = ref($proto) || $proto;

  # Singleton
  return $Q if defined $Q;

  # Populate object creation hash with defaults
  my %params = ( simdb => 0,
                 nocomplete => 0,
                 taskname => TASKNAME,
                 maxwidth => MAXWIDTH,
                 nentries => NENTRIES,
               );

  # Now read the arguments and merge with default parameters
  my %args = @_;
  for (keys %args) {
    $params{lc($_)} = $args{$_};
  }

  # Create the object
  my $q = bless {}, $class;

  # And fill it up
  for (keys %params) {
    if ( $q->can( $_ ) ) {
      $q->$_( $params{$_});
    }
  }

  # Now we need to startup DRAMA
  $q->init_msgsys();

  # and the parameter system
  $q->init_pars();

  # and check for any left over MSB accepts
  $q->process_pending_msbcomplete();

  # Cache it and return it
  $Q = $q;
  return $Q;
}

=item B<init_msgsys>

Initialise the DRAMA message system. This will configure the application
as a DRAMA task and associate actions in the task with subroutines found
in this package. Automatically called by the constructor. Calling this
method twice has no effect.

  $Q->init_msgsys();

Uses the taskname stored in the object via the C<taskname> method.

=cut

sub init_msgsys {
  my $self = shift;

  my $taskname = $self->taskname;
  croak "init_msgsys: Must supply a task name" unless defined $taskname;

  # Start the DRAMA system
  #DPerlInit($taskname);
  Jit::Init( $taskname );
  print "--- JIT Initialised\n";
  # Set up the actions
  my $flag = 0;                 # Not spawnable
  DRAMA::ErsPush();
  my $status = new DRAMA::Status;

  # Basic control
  Dits::DperlPutActions("POLL",       \&POLL,\&KICK_POLL,$flag,undef,$status);
  Dits::DperlPutActions("EXIT",       \&EXIT,    undef,0,undef,$status);
  Dits::DperlPutActions("STARTQ",     \&STARTQ,  undef,$flag,undef,$status);
  Dits::DperlPutActions("STOPQ",      \&STOPQ,   undef,$flag,undef,$status);

  # Put stuff in the queue
  Dits::DperlPutActions("LOADQ",      \&LOADQ,  undef,$flag,undef,$status);
  Dits::DperlPutActions("ADDBACK",    \&ADDBACK,  undef,$flag,undef,$status);
  Dits::DperlPutActions("ADDFRONT",   \&ADDFRONT,  undef,$flag,undef,$status);
  Dits::DperlPutActions("INSERTQ",    \&INSERTQ,  undef,$flag,undef,$status);

  # Remove stuff from the queue
  Dits::DperlPutActions("CLEARQ",     \&CLEARQ,    undef,$flag,undef,$status);
  Dits::DperlPutActions("MSBCOMPLETE",\&MSBCOMPLETE,    undef,0,undef,$status);
  Dits::DperlPutActions("CUTQ",       \&CUTQ,    undef,0,undef,$status);
  Dits::DperlPutActions("CUTMSB",     \&CUTMSB,    undef,0,undef,$status);
  Dits::DperlPutActions("SUSPENDMSB", \&SUSPENDMSB, undef,0,undef,$status);

  # Manipulation of individual entries
  #Dits::DperlPutActions("REPLACEQ",   \&REPLACEQ,undef,$flag,undef,$status);
  Dits::DperlPutActions("MODENTRY",\&MODENTRY,undef,$flag,undef,$status);
  Dits::DperlPutActions("GETENTRY",   \&GETENTRY,    undef,0,undef,$status);
  Dits::DperlPutActions("CLEARTARG",  \&CLEARTARG,    undef,0,undef,$status);


  # Check status
  if (!$status->Ok) {
    my $txt = $status->ErrorText;
    $status->Annul();
    DRAMA::ErsPop();
    croak "Error initialising actions: $txt";
  }
  DRAMA::ErsPop();

  return;
}

=item B<init_pars>

Initisalise the parameter system.

  $Q->init_pars();

Called as part of object instantiation. Should not be called
again. See also the C<nentries> and C<maxwidth> methods.

Configures the following parameters:

=over 8

=item STATUS

Whether the queue is running or not. A String.

=item INDEX

An integer corresponding to the position of the currently selected
queue entry.

=item TIMEONQUEUE

Time remaining on the queue following the current highlight (integer
seconds).

=item CURRENT

String representing the item on the queue that is currently being
observed.

=item Queue

A string array of width C<maxwidth> characters and C<nentries> lines
corresponding to a textual representation of the current entries in the queue.
Currently one entry is equivalent to one line in this array.

=item FAILURE

An SDS structure filled when the queue determines that more information
is required before the entry can be sent to the observing system. For
example, a request for a calibration target.

=item MSBCOMPLETED

An SDS structure containing information on MSBs that are awaiting
acceptance or rejection by the observer.

=item ALERT

Set to non-zero value when the queue monitor should alert the operator that
there is a problem with the observation. The allowed values are defined as
constants in Queue::Constants and the queue monitor can behave accordingly.

=back

=cut

sub init_pars {
  my $self = shift;

  my $nentries = $self->nentries;
  my $maxwidth = $self->maxwidth;

  # Validation
  croak "init_pars: Number of entries must be defined"
    unless defined $nentries;

  croak "init_pars: Width of entry must be defined"
    unless defined $maxwidth;

  DRAMA::ErsPush();
  my $status = new DRAMA::Status;

  #  my $sdp = new Sdp;
  my $sdp = Dits::GetParId();
  $sdp->Create("STATUS","STRING",'Stopped');
  $sdp->Create("ALERT", "INT", 0 );
  $sdp->Create("INDEX","INT",0);
  $sdp->Create("TIMEONQUEUE","INT",0);
  $sdp->Create("CURRENT","STRING",'None');

  my $queue_sds = Sds->Create("Queue",undef,Sds::STRUCT,0,$status);
  $queue_sds->Create("Contents",undef,Sds::CHAR,
                     [$maxwidth,$nentries],$status);

  # This contains any information on entries that need more information
  my $failure_sds = Sds->Create("FAILURE",undef, Sds::STRUCT,0,$status);

  # This contains queue completion triggers
  my $msbcomplete_sds = Sds->Create("MSBCOMPLETED",undef, Sds::STRUCT,0,
                                    $status);

  # Initialise the arrays that hold the queue entries
  {
    my @array = ();
    my $csds = $queue_sds->Find('Contents',$status);
    $csds->PutStringArrayExists(\@array, $status);
  }

  # Store the SDS items in the parameter system
  $sdp->Create('','SDS',$queue_sds);
  $sdp->Create('','SDS',$failure_sds);
  $sdp->Create('','SDS',$msbcomplete_sds);

  # Have to make sure that these SDS objects don't go out of scope
  # and destroy their contents prior to use in the parameter system
  # Can either put them in a hash inside $self OR simply prevent them
  # from being freed. Cache them for now
  $self->_param_sds_cache( $queue_sds, $failure_sds, $msbcomplete_sds );

  # Store the parameters in the object
  $self->_params( $sdp );

  # Check status
  if (!$status->Ok) {
    my $txt = $status->ErrorText;
    $status->Annul();
    DRAMA::ErsPop();
    croak "Error initialising parameters: $txt";
  }
  DRAMA::ErsPop();
  return;
}

=back

=head2 Accessor Methods

=over 4

=item B<nentries>

Maximum number of entries in the queue. Can not be modified after object
instantiation.

  $num = $Q->nentries;

=cut

sub nentries {
  my $self = shift;
  if (@_) {
    croak "nentries is read-only" if defined $self->{NENTRIES};
    my $new = shift;

    # Validate
    croak "nentries must be defined" unless defined $new;
    croak "nentries must be positive" unless $new > 0;

    # Store as integer
    $self->{NENTRIES} = int( $new );
  }
  return $self->{NENTRIES};
}

=item B<maxwidth>

Maximum width of textual representation of entry in the queue. Can not
be modified after object instantiation.

  $width = $Q->maxwidth;

=cut

sub maxwidth {
  my $self = shift;
  if (@_) {
    croak "maxwidth is read-only" if defined $self->{MAXWIDTH};
    my $new = shift;

    # Validate
    croak "maxwidth must be defined" unless defined $new;
    croak "maxwidth must be positive" unless $new > 0;

    # Store as integer
    $self->{MAXWIDTH} = int( $new );
  }
  return $self->{MAXWIDTH};
}

=item B<taskname>

Name of the queue task as it appears to the DRAMA message system.

 $task = $Q->taskname;

=cut

sub taskname {
  my $self = shift;
  if (@_) {
    croak "taskname is read-only" if defined $self->{TASKNAME};
    $self->{TASKNAME} = shift;
  }
  return $self->{TASKNAME};
}

=item B<simdb>

Control whether the queue is allowed to send completion messages to the
MSB database. Default is to allow this.

=cut

sub simdb {
  my $self = shift;
  if (@_) {
    $self->{SIMDB} = shift;
  }
  return $self->{SIMDB};
}

=item B<nocomplete>

Control whether the queue is allowed to store completion parameters.
Default is to allow this. If completion parameters are disabled the simdb
flag will probably have no effect.

=cut

sub nocomplete {
  my $self = shift;
  if (@_) {
    $self->{NOCOMPLETE} = shift;
  }
  return $self->{NOCOMPLETE};
}

=item B<verbose>

Controls whether verbose messaging should be enabled. Default is false.

  $Q->verbose( 1 );
  $verb = $Q->verbose();

=cut

sub verbose {
  my $self = shift;
  if (@_) {
    $self->{VERBOSE} = shift;
  }
  return $self->{VERBOSE};
}

=item B<queue>

The underlying C<Queue> object that is being manipulated by the backend.

  $Q->queue( new Queue::JCMT );
  $queue = $Q->queue;

=cut

sub queue {
  my $self = shift;
  if (@_) {
    my $q = shift;
    croak "queue: Must be a Queue object"
      unless UNIVERSAL::isa( $q, "Queue");
    $self->{QUEUE} = $q;
  }
  return $self->{QUEUE};
}

=item B<polltime>

Time (in seconds) to sleep between polls of the queue backend.

  $Q->polltime( 1 );

Defaults to 1 second.

=cut

sub polltime {
  my $self = shift;
  if (@_) {
    $self->{POLLTIME} = shift;
  }
  return 1 unless defined $self->{POLLTIME};
  return $self->{POLLTIME};
}

=item B<queueid>

Index corresponding to the number of MSBs that have been added to the
queue. This should probably be tracked by the queue itself but currently
it is not because the queue does not add a collection of entries in a single
go, it just adds an array of entries.

=cut

sub queueid {

}

=item B<_params>

Parameter system (C<Sdp>) object associated with this server.
Initialised by C<init_params> method.

  $sdp = $Q->_params;

=cut

sub _params {
  my $self = shift;
  if (@_) {
    my $par = shift;
    croak "queue: Must be a Sdp object"
      unless UNIVERSAL::isa( $par, "Sdp");
    $self->{PARAMS} = $par;
  }
  return $self->{PARAMS};
}

=item B<_param_sds_cache>

Internal cache of SDS objects associated with the parameter system.
Stored as a simple array and overwritten each time this is called.
Assumption is this will be caused once with a list of SDS objects
that should not be destroyed. If we do not do this the destructors
will run after parameter initialisation and the SDS structure in the
parameter system will be deleted.

=cut

sub _param_sds_cache {
  my $self = shift;
  if (@_) {
    $self->{_PARAM_SDS_CACHE} = [ @_ ];
  }
  return $self->{_PARAM_SDS_CACHE};
}

=item B<_local_index>

Internal record of the current index position in the queue. This
is independent of both the queue idea of the index and the actual
DRAMA parameter since this enables the queue task to work out whether
one or the other has changed and therefore act appropriately. Initialised
to zero.

Not to be used outside of this module.

=cut

sub _local_index {
  my $self = shift;
  if (@_) {
    $self->{_LOCAL_INDEX} = shift;
  }
  $self->{_LOCAL_INDEX} = 0 unless defined $self->{_LOCAL_INDEX};
  return $self->{_LOCAL_INDEX};
}

=item B<_msbcomplete_table>

Return a reference to a hash representing the MSB completion
information that is currently awaiting approval.

 $msbcompl = $self->_msbcomplete_table();

=cut

sub _msbcomplete_table {
  my $self = shift;
  $self->{MSBCOMPLETE} = {} unless defined $self->{MSBCOMPLETE};
  return $self->{MSBCOMPLETE};
}

=back

=head2 Main methods

=over 4

=item B<mainloop>

Begin the main event loop. Also initialises any actions that are meant to
be started internally (e.g. the polling loop). Returns when the queue
is shut down.

  $Q->mainloop();

A C<Queue> object must be registered before this method can be invoked.

=cut

sub mainloop {
  my $self = shift;

  # Check we have a valid taskname
  my $taskname = $self->taskname;
  croak "init_loop: Unable to determine own task name"
    unless defined $taskname;

  # Verify that we have a Queue object
  croak "init_loop: Must register a Queue object with the server task"
    unless defined $self->queue;

  # Start the polling
  obey $taskname,"POLL";

  # Start the DRAMA event loop
  my $status = new DRAMA::Status;
  Dits::MainLoop($status);

  # What should we do about status???

}

=item B<addmessage>

Given a message status and a message string, "publish"
that message as a parameter and simultaneously "print"
it using MsgOut. This method is useful for monitor
tasks that did not initiate the action that generates
the message.

  $Q->addmessage( $msgstatus, $text );

Message status can be a blessed DRAMA status object or a simple
integer (where '0' is good status aka STATUS__OK).

Returns true if the message could be propagated, and false otherwise.

Multiple lines can be supplied as a list.

  $Q->addmessage( $msgstatus, @text );

=cut

sub addmessage {
  my $self = shift;
  my ($msgstatus, @lines) = @_;

  # trap for DRAMA status
  if (UNIVERSAL::can($msgstatus, "GetStatus")) {
    # extract the value of the status
    $msgstatus = $msgstatus->GetStatus;
  }

  # split messages on new lines
  @lines = map { split(/\n/,$_) } @lines;

  # Calculate a timestamp - note that this doesn't have to accurately
  # reflect the time the message was sent from the client. It's simply meant
  # as a debugging aid to get a reasonable idea of when something occurred
  # for the log
  my $time = DateTime->now->set_time_zone( 'UTC' );
  my $tstamp = colored( $time->strftime("%T").":", "green");
  @lines = map { "$tstamp$_" } @lines;

  # Create a new error context
  DRAMA::ErsPush();
  my $status = new DRAMA::Status;

  # Retrieve the parameter system
  my $sdp = $self->_params;

  if (!defined $msgstatus) {
    Carp::cluck("msgstatus not defined");
  }

  # Either use MsgOut or ErsOut
  if ($msgstatus == DRAMA::STATUS__OK) { # STATUS__OK
    # Send back through normal channels
    # one line at a time (else the parameter monitoring doesn't pick it up properly)
    for (@lines) {
      DRAMA::MsgOut($status, $_);
      print "MsgOut: $_\n";
    }
  } else {
    # This relies on JIT populating JIT_ERS_OUT
    DRAMA::ErsPush();
    my $lstat = new DRAMA::Status;
    $lstat->SetStatus( $msgstatus );
    $lstat->ErsOut( 0, join("\n",@lines));
    DRAMA::ErsPop();
    print "ErsOut: $_\n" for @lines;
  }

  unless ($status->Ok) {
    Carp::cluck "Error populating message parameters:". $status->ErrorText;
    $status->Annul;
    DRAMA::ErsPop();
    return 0;
  }

  return 1;
}

=item B<ersRep>

Associate an error with a status object and configure the parameter
monitoring. Functionally equivalent to

  $status->SetStatus( statusvalue );
  $status->ErsRep(0, "Error message");
  $Q->addmessage( $status, "Error Message");

ie makes sure that the error is associated with a status object and
also propagated through the parameter monitoring system. Note that this
causes a message to appear in the monitor even though the message itself
may never be sent through the Ers system via ErsOut. Only use this method
if you want an immediate error message now and the possibility of an
explicit error message later.

=cut

sub ersRep {
  my $self = shift;
  croak "Q->ersRep Not trustworthy yet!\n";
}

=item B<cutmsb>

Cut the supplied C<Queue::MSB> object from the queue.

  $Q->cutmsb( $msb );

No action if $msb is not defined.

=cut

sub cutmsb {
  my $self = shift;
  my $msb = shift;
  return unless defined $msb;

  croak "$Q->cutmsb: Must supply a Queue::MSB object as argument"
    unless $msb->isa("Queue::MSB");

  # Get an entry from the MSB
  my $entry = $msb->entries->[0];

  # Convert to an index
  if ($entry) {
    my $index = $self->queue->contents->getindex( $entry );
    if (defined $index) {
      # Cut it
      $self->queue->contents->cutmsb( $index );
    }
  }

  return;
}

=item B<set_msbcomplete_parameter>

Set the contents of the MSB complete parameter.

Arguments: Inherited status, information hash.

This method takes the data (a hash of information that should be sent
to the monitoring system), retrieves the MSB transaction ID as a
unique key it and places it into the parameter. Use
C<clear_msbcomplete_parameter> method to remove it. This allows us to
stack up MSB completion requests if we do not have a queue monitor
running.

  $Q->set_msbcomplete_parameter( $status, %details)

Note that the MSB key is treated as a special case (the relevant
Queue::MSB object) and is not stored directly in the parameter.

The expectation is that %details includes sufficient information
to identify the MSB. It will likely include the position of the
MSB in the queue, the projectid and the MSBID.

If C<nocomplete> is true, this method will cut the MSB and will not
store any completion parameters.

=cut

sub set_msbcomplete_parameter {
  my $self = shift;
  my $status = shift;
  return unless $status->Ok;

  # Read the arguments
  my %details = @_;

  # Dump the completion details but strip out the Entry object because
  # the config is enormous
  my %copy = %details;
  delete $copy{MSB};
  print Dumper(\%copy);
  print ($status->Ok ? "status ok\n" : "status bad\n");

  # if we have disabled completion then we should go no further
  if ($self->nocomplete) {
    # Look for the MSB object
    my $msb = $details{MSB};

    if (defined $msb) {
      # someone has to cut the MSB from the queue
      $self->addmessage( $status,
                         "Removing completed MSB from queue without prompting user");

      $self->cutmsb( $msb );
    }

    # return since we do not want to store the parameter
    return;
  }

  # Read the MSBCOMPLETED parameter
  my $sdp = $self->_params;
  my $sds = $sdp->GetSds('MSBCOMPLETED',$status);
  return undef unless defined $sds;

  # calculate the MSB transaction ID. It can not be the unique key because
  # it is too long for SDS.
  $details{MSBTID} = $details{MSB}->transid if (exists $details{MSB} && defined $details{MSB});

  # Choose a unique key for the completion hash - timestamp is the only
  # choice given length constraints. Making the MSBTID shorter by dropping
  # the milliseconds would also be possible
  my $compkey = $details{TIMESTAMP};

  # The MSB object should not go in the SDS structure
  # so we store all this information in a hash outside
  # of it [that only the *_msbcomplete functions use -
  # this is essentially a Queue::MSBComplete object
  # Take a copy
  $self->_msbcomplete_table->{$details{TIMESTAMP}} = { %details };

  # Write to file store in case we are shutdown before we have accepted
  $self->archive_pending_msbcomplete();

  # Remove the MSB field
  delete $details{MSB};

  # Add it to the parameter
  # standard kluge
  bless $sds, "Sds";

  # Note that keys in Sds structures can not be more than 15 characters.
  $sds->PutHash( \%details, "$compkey", $status);

  print "Listing SDS for MSB transaction $details{MSBTID}:\n";
  $sds->List($status);

  # Notify the parameter system
  $sdp->Update($sds,$status);

  print "Get to the end of qcompleted param setting\n";
  return;
}

=item B<clear_msbcomplete_parameter>

Remove the completed information from the DRAMA parameter.

 $Q->clear_msbcomplete_parameter($status, $compkey);

The completion key must match a MSB completion key stored in the
completion table.

=cut

sub clear_msbcomplete_parameter {
  my $self = shift;
  my $status = shift;
  return unless $status->Ok;

  # Read the MSBCOMPLETED parameter
  my $sdp = $self->_params;
  my $sds = $sdp->GetSds('MSBCOMPLETED',$status);
  return undef unless defined $sds;

  my $compkey = shift;

  # Now need to look for the completion object
  # (use a private status)
  DRAMA::ErsPush();
  my $lstat = new DRAMA::Status;

  # Have to remove the old entries
  my $updated;
  {
    my $detsds = $sds->Find("$compkey", $lstat);

    if ($detsds) {
      # if we have a DETAILS object we need to
      # configure it so that it is deleted when it goes out of scope
      $detsds->flags(1,1,1);

      # We are going to destroy it
      $updated = 1;

    }

  }
  $lstat->Annul() unless $lstat->Ok();
  DRAMA::ErsPop();

  # And we need to trigger a parameter update notification
  # if it was changed
  $sdp->Update($sds, $status) if $updated;

  # Clear the hash entry and the file cache
  delete $self->_msbcomplete_table->{$compkey};
  $self->archive_pending_msbcomplete();

  return;
}

=item B<get_msbcomplete_parameter_transid>

Retrieve the MSBID and Projectid information associated with the
supplied completion key.  Simply returns the hash entry in the MSB
completion table.  (the pseudo C<Queue::MSBComplete> object).

 %details = $Q->get_msbcomplete_parameter_transid($status,$compkey);

=cut

sub get_msbcomplete_parameter_transid {
  my $self = shift;
  my $status = shift;
  return unless $status->Ok;
  my $compkey = shift;

  if (exists $self->_msbcomplete_table->{$compkey}) {
    return %{ $self->_msbcomplete_table->{$compkey} };
  } else {
    return ();
  }

}

=item B<archive_pending_msbcomplete>

Write the pending MSB completion information in case the queue is shut
down without having resolved all MSB accepts/rejects.

  $Q->archive_pending_msbcomplete();

Information is written to a file that will be read on runup.

If no information is pending, no file is written and any pre-existing
file is removed.

If the file can not be written, we carry on about our business rather
than treating it as fatal.

=cut

sub archive_pending_msbcomplete {
  my $self = shift;
  # use Storable since we do not care about the format
  # Strip out the MSB object since it won't be valid when the
  # new queue is run up
  my %pending;

  my $table = $self->_msbcomplete_table;
  for my $compkey (keys %$table) {
    my %temp = %{$table->{$compkey}};
    delete $temp{MSB};
    $pending{$compkey} = \%temp;
  }

  # if we have no keys delete the file rather than storing
  # an empty
  if (keys %pending) {
    eval {
      nstore( \%pending, $self->_pending_msb_filename );
    };
    if ($@) {
      print "Log warning: Unable to write pending complete information to ".$self->_pending_msb_filename.": $@";
    }
  } else {
    unlink $self->_pending_msb_filename;
  }
  return;
}

=item B<process_pending_msbcomplete>

Process any pending MSB complete information. The contents of
the data file are read and placed into completion parameters to
be picked up by the queue.

  $self->process_pending_msbcomplete();

=cut

sub process_pending_msbcomplete {
  my $self = shift;
  my $pending;
  eval {
    $pending = retrieve( $self->_pending_msb_filename );
  };
  my $status = new DRAMA::Status;
  if (defined $pending) {
    for my $compkey (keys %$pending) {
      $self->set_msbcomplete_parameter( $status, %{$pending->{$compkey}} );
    }
  }
}

=back

=head1 CALLBACKS

These subroutines are not meant to be called directly. They are callbacks
that will be associated with DRAMA actions when the C<init_msgsys> routine
is called.

Note also that none of these callbacks access the server object using
the argument stack (since the current perl implementation is not as
flexible as the Tk callback system). This means that the callbacks access
the Queue DRAMA configuration information (not necessarily required) using
a global lexical variable.

=over 4


=item B<EXIT>

Cause the task to shutdown and exit. No arguments.

=cut

# EXIT action
sub EXIT {
  my $status = shift;
  Jit::ActionEntry( $status );
  return $status unless $status->Ok;
  # pre-emptive tidy
  $Q->queue->contents->clearq;
  Dits::PutRequest(Dits::REQ_EXIT,$status);
  Jit::ActionExit( $status );
  return $status;
}

=item B<STARTQ>

Start the queue. ALERT parameter is reset.

=cut

sub STARTQ {
  Jit::ActionEntry( $_[0] );
  return $_[0] unless $_[0]->Ok;
  unless ($Q->queue->backend->qrunning) {
    $Q->queue->startq;
    $Q->addmessage($_[0], "Queue is running");
  }
  # still sync parameters even if we do not print the message
  update_status_param($_[0]);
  update_alert_param(0, $_[0]);
  clear_failure_parameter($_[0]);
  Jit::ActionExit( $_[0] );
  return $_[0];
}

=item B<STOPQ>

Stop the queue from sending any more entries to the backend.

Optional second argument will set the ALERT parameter to the supplied constant.
ALERT will be cleared if STOPQ is called without this parameter or if STARTQ
is called.

=cut

sub STOPQ {
  Jit::ActionEntry( $_[0] );
  return $_[0] unless $_[0]->Ok;
  if ($Q->queue->backend->qrunning) {
    $Q->queue->stopq;
    $Q->addmessage($_[0], "Queue is stopped");
  }
  # still sync the parameter
  update_status_param($_[0]);

  # Set the alert parameter
  update_alert_param($_[1], $_[0]);

  Jit::ActionExit( $_[0] );
  return $_[0];
}

=item B<CLEARQ>

Remove all entries from the queue.

=cut

sub CLEARQ {
  Jit::ActionEntry( $_[0] );
  return $_[0] unless $_[0]->Ok;
  $Q->queue->contents->clearq;
  $Q->addmessage($_[0], "Queue cleared");
  update_contents_param($_[0]);
  update_index_param($_[0]);
  Jit::ActionExit( $_[0] );
  return $_[0];
}


=item B<LOADQ>

Clear the queue and load the specified entries onto it.
Accepts a single argument that specifies the XML content
description of the entries. See C<Sds_to_Entry>.

=cut

sub LOADQ {
  my $status = shift;
  Jit::ActionEntry( $status );
  return $status unless $status->Ok;

  $Q->addmessage( $status, "Running LOADQ") if $Q->verbose;

  my $argId = Dits::GetArgument;

  # If no argument simply return
  if (!defined $argId) {
    $status->SetStatus( Dits::APP_ERROR );
    $status->ErsRep( 0, "Error obtaining Action Argument structure. This should be impossible!");
    Jit::ActionExit( $status );
    return $status;
  }

  # Extract the entries from the argument
  my @entries = &Sds_to_Entry( $argId );

  $Q->queue->contents->loadq( @entries );


  # Update the parameter
  update_contents_param($status);
  update_index_param($status);

  #  print Dumper($grp);
  #  print Dumper(\@entries);
  #  print Dumper($Q->queue);
  #  print "Found " . scalar(@entries) . " entries\n";

  Jit::ActionExit( $status );
  return $status;
}


=item B<ADDBACK>

Add the supplied entries to the back of the queue.
Accepts the same arguments as C<LOADQ>.

If the time remaining on the queue exceeds a threshold
the action will fail and return with bad status.

=cut

sub ADDBACK {
  my $status = shift;
  Jit::ActionEntry( $status );
  return $status unless $status->Ok;

  $Q->addmessage($status, "Running ADDBACK") if $Q->verbose;

  # Verify time remaining on queue
  verify_time_remaining( $status );
  return $status unless $status->Ok;

  # Read the arguments
  my $argId = Dits::GetArgument;

  # If no argument simply return
  if (!defined $argId) {
    $status->SetStatus( Dits::APP_ERROR );
    $status->ErsRep( 0, "Error obtaining Action Argument structure. This should be impossible!");
    Jit::ActionExit( $status );
    return $status;
  }

  # Retrieve the queue entries associated with the args
  my @entries = &Sds_to_Entry($argId);

  if ($#entries > -1) {
    # Add these entries to the back of the queue
    $Q->queue->contents->addback(@entries);

    # Update the DRAMA parameters. Index will not have changed
    update_contents_param($status);

  }

  Jit::ActionExit( $status );
  return $status;
}

=item B<ADDFRONT>

Add the supplied entries to the front of the queue.
Accepts the same arguments as C<LOADQ>.

If the time remaining on the queue exceeds a threshold
the action will fail and return with bad status.

=cut

sub ADDFRONT {
  my $status = shift;
  Jit::ActionEntry( $status );
  return $status unless $status->Ok;

  $Q->addmessage($status, "Running ADDFRONT") if $Q->verbose;

  # Verify time remaining on queue
  verify_time_remaining( $status );
  return $status unless $status->Ok;

  # Read the arguments
  my $argId = Dits::GetArgument;

  # If no argument simply return
  if (!defined $argId) {
    $status->SetStatus( Dits::APP_ERROR );
    $status->ErsRep( 0, "Error obtaining Action Argument structure. This should be impossible!");
    Jit::ActionExit( $status );
    return $status;
  }

  # Retrieve the entries associated with the args
  my @entries = &Sds_to_Entry($argId);

  if ($#entries > -1) {
    # Add these entries to the back of the queue
    $Q->queue->contents->addfront(@entries);

    # Update the DRAMA parameters
    # Index will have changed
    update_contents_param($status);
    update_index_param($status);
  }
  Jit::ActionExit( $status );
  return $status;
}


=item B<INSERTQ>

Insert calibration observations into the queue at the current highlight
or at the specified index. Note that these calibrations are not
treated as MSBs.

Observations are specified in the same way as for C<LOADQ>.

The optional index can be specified as "Argument2".

=cut

sub INSERTQ {
  my $status = shift;
  Jit::ActionEntry( $status );
  return $status unless $status->Ok;

  $Q->addmessage( $status, "Running INSERTQ") if $Q->verbose;

  my $argId = Dits::GetArgument;

  # If no argument simply return
  if (!defined $argId) {
    $status->SetStatus( Dits::APP_ERROR );
    $status->ErsRep( 0, "Error obtaining Action Argument structure. This should be impossible!");
    Jit::ActionExit( $status );
    return $status;
  }

  # Get the entries [mark them as calibrations]
  my @entries = &Sds_to_Entry( $argId, 1);

  # Tie the Sds to a hash to get at the second argument
  my %sds;
  tie %sds, 'Sds::Tie', $argId;

  # Get the index. Can come from the SDS
  my $newindex;
  if (exists $sds{Argument2}) {
    $newindex = $sds{Argument2};
  } else {
    # get the current index
    my $cur = $Q->queue->contents->curindex;
    if (defined $cur) {
      $newindex = $cur + 1;
    } else {
      $newindex = 0;
    }
  }

  $Q->queue->contents->insertq($newindex, @entries );

  # Contents will have changed and index may have changed
  update_contents_param($status);
  update_index_param($status);

  #  print Dumper($grp);
  #  print Dumper(\@entries);
  #  print Dumper($Q->queue);
  #  print "Found " . scalar(@entries) . " entries\n";

  Jit::ActionExit( $status );
  return $status;
}

=item B<MODENTRY>

Modify the state of the specified entry. The arguments
are:

=over 8

=item INDEX

The index of the entry that is being modified. This argument is mandatory.

=item PROPAGATE

Propagate the modification specified in this action to subsequent
entries in the queue. If not specified, assumes no propagation.

=item TARGET

The entry target information should be modified. This argument is
a string consisting of TCS XML. All TAGS will be read and stored in the
entry.

=back

The status of the entry matches that of the one it replaces
ie whether it is the first or last obs in an MSB. It is automatically
associated with the MSB of the entry it is replacing.

=cut

sub MODENTRY {
  my $status = shift;
  Jit::ActionEntry( $status );
  return $status unless $status->Ok;

  $Q->addmessage( $status, "Running MODENTRY") if $Q->verbose;

  my $argId = Dits::GetArgument;

  # If no argument simply return
  return unless defined $argId;

  # tie the argId to a perl Hash
  $argId->List($status);
  my %sds;
  tie %sds, 'Sds::Tie', $argId;

  print "RECEIVED Argument for entry modification: ". Dumper(\%sds);

  my $index = $sds{INDEX};
  my $prop = $sds{PROPAGATE};

  my $tcs;
  if ( exists $sds{TARGET} ) {
    my $xml = $sds{TARGET};

    # Create TCS object
    # disable validation since we are not expecting a DTD with this snippet
    $tcs = new JAC::OCS::Config::TCS( XML => $xml, validation => 0 );

  } else {
    $Q->addmessage( $status, "Nothing to modify");
    return $status;
  }

  # Get the current entry
  my $curr = $Q->queue->contents->getentry($index);

  # Synchronize target information
  $curr->setTarget( $tcs );

  # if we are propogating source information we need to do it now
  $Q->queue->contents->propsrc($index)
    if $prop;

  # Always clear if we have tweaked something
  update_contents_param($status);
  update_index_param($status);

  Jit::ActionExit( $status );
  return $status;
}

=item B<CLEARTARG>

Clear the target information associated with the specified index.
"Argument1" contains the index entry.

=cut

sub CLEARTARG {
  my $status = shift;
  Jit::ActionEntry( $status );
  return $status unless $status->Ok;

  $Q->addmessage( $status, "Clearing target information")
    if $Q->verbose;

  my $argId = Dits::GetArgument;

  # If no argument simply return
  return $status unless defined $argId;

  # tie the argId to a perl Hash
  $argId->List($status);

  #  if ($status->Ok) {
  DRAMA::ErsPush();
  my %sds;
  tie %sds, 'Sds::Tie', $argId;
  my $index = $sds{Argument1};
  $Q->queue->contents->clear_target( $index );
  DRAMA::ErsPop();
  #  }
  # update contents string
  update_contents_param($status);
  Jit::ActionExit( $status );
  return $status;
}


=item B<CUTQ>

Remove entries beginning at the specified index position.  The index
is mandatory (either as "Argument1" or as "INDEX") and an optional
parameter can be used to specify the number of entries to remove
("Argument2" or "NCUT"). Defaults to a single entry.

=cut

sub CUTQ {
  my $status = shift;
  Jit::ActionEntry( $status );
  return $status unless $status->Ok;

  $Q->addmessage($status, "Running CUTQ") if $Q->verbose;

  my $argId = Dits::GetArgument;

  # If no argument simply return
  if (!defined $argId) {
    $status->SetStatus( Dits::APP_ERROR );
    $status->ErsRep( 0, "Error obtaining Action Argument structure. This should be impossible!");
    Jit::ActionExit( $status );
    return $status;
  }

  # Retrieve the INDEX and NCUT integers from the Args
  # Easier if I tie to a hash
  my %sds;
  tie %sds, 'Sds::Tie', $argId;

  print "Argument to CUT:".Dumper(\%sds);

  my ($index, $ncut);
  if (exists $sds{INDEX}) {
    $index = $sds{INDEX};
    $ncut = $sds{NCUT};
  } elsif (exists $sds{Argument1}) {
    $index = $sds{Argument1};
    $ncut = $sds{Argument2};
  } else {
    $status->SetStatus( Dits::APP_ERROR );
    $status->ErsRep( 0, "Unable to determine cut position.");
    Jit::ActionExit( $status );
    return $status;
  }

  # default to only a single entry
  $ncut = 1 unless defined $ncut;

  $Q->addmessage($status,
                 "Removing $ncut observation[s] starting from index $index");

  # CUT
  $Q->queue->contents->cutq($index, $ncut);

  # Update the DRAMA parameters
  update_contents_param($status);
  update_index_param($status);

  Jit::ActionExit( $status );
  return $status;
}

=item B<CUTMSB>

Remove the MSB associated with the currently highlighted observation
or the supplied index. The optional index can be specified as either
"Argument1" or as "INDEX" in the SDS argument structure.

=cut

sub CUTMSB {
  my $status = shift;
  Jit::ActionEntry( $status );
  return $status unless $status->Ok;

  $Q->addmessage($status, "Running CUTMSB") if $Q->verbose;

  my $argId = Dits::GetArgument;

  # If no argument simply return
  if (!defined $argId) {
    $status->SetStatus( Dits::APP_ERROR );
    $status->ErsRep( 0, "Error obtaining Action Argument structure. This should be impossible!");
    Jit::ActionExit( $status );
    return $status;
  }

  # Retrieve the INDEX integer from the Args
  my %sds;
  tie %sds, 'Sds::Tie', $argId;

  print Dumper(\%sds);

  # index can be undefined
  my $index;
  if (exists $sds{INDEX}) {
    $index = $sds{INDEX};
  } elsif (exists $sds{Argument1}) {
    $index = $sds{Argument1};
  }

  if (defined $index) {
    $Q->addmessage( $status, "Cutting MSB around index $index");
  } else {
    $Q->addmessage( $status, "Cutting current MSB");
  }

  # Make sure there are entries in the queue
  if (! $Q->queue->contents->countq) {
    $status->SetStatus( Dits::APP_ERROR );
    $status->ErsRep( 0, "No entries in queue. Unable to cut MSB");
    Jit::ActionExit( $status );
    return $status;
  }

  $Q->queue->contents->cutmsb($index);
  update_contents_param($status);
  update_index_param($status);

  Jit::ActionExit( $status );
  return $status;
}

=item B<SUSPENDMSB>

Suspend the MSB at the currently highlighted position.  The MSB is
removed from the queue. This method takes no arguments.

=cut

sub SUSPENDMSB {
  my $status = shift;
  Jit::ActionEntry( $status );
  return $status unless $status->Ok;

  # first get the current entry
  my $entry = $Q->queue->contents->curentry;
  unless ($entry) {
    $status->SetStatus( Dits::APP_ERROR );
    $status->ErsRep(0, "Suspend MSB attempted but no entry available");
    Jit::ActionExit( $status );
    return $status;
  }

  # then ask the entry for the MSBID, ProjectID and ObsLabel
  # these should be methods of the entry but for now
  # we assume the "entity" has them
  my $proj = $entry->projectid;
  my $msbid = $entry->msbid;
  my $label = $entry->entity->getObsLabel;

  if ($proj && $msbid && $label) {
    my $msbtid = $entry->msbtid;
    try {
      # Suspend the MSB unless we are in simulate mode
      my $msg;
      if ($Q->simdb) {
        $msg = "[in simulation without modifying the DB]";
      } else {
        OMP::MSBServer->suspendMSB($proj, $msbid, $label, $msbtid);
        $msg = '';
      }

      $Q->addmessage($status, "MSB for project $proj has been suspended at the current observation $msg");

    } otherwise {
      # Error in suspend
      # Big problem with OMP system
      my $E = shift;
      $status->SetStatus( Dits::APP_ERROR );
      $status->ErsRep(0,"Error marking msb $msbid as done: $E");
    };

    # Return if we have bad status
    if (!$status->Ok) {
      Jit::ActionExit( $status );
      return $status;
    }

    # Now need to cut the MSB without triggering accept/reject
    my $msb = $entry->msb;
    if (defined $msb) {
      $msb->hasBeenObserved(0);
    }

    # and cut it
    $Q->queue->contents->cutmsb( $Q->queue->contents->curindex );

    # Make sure things are up to date (although POLL should deal with that)
    update_contents_param($status);
    update_index_param($status);
  } else {
    $status->SetStatus( Dits::APP_ERROR );
    $status->ErsRep(0, "Attempted to suspend MSB but was unable to determine either the label, projectid or MSBID from the current entry");
  }
  Jit::ActionExit( $status );
  return $status;
}


=item B<POLL>

This is the core action in the queue. It continually reschedules
itself checking to make sure that the queue is in a good state and
sending the next entry if the queue is active and the backend is ready
to accept it. This action is triggered by the queue on startup. It can
be kicked to disable the rescheduling.

=cut

# continuously rescheduling action
sub POLL {
  my $status = shift;
  #Jit::ActionEntry( $status );
  return $status unless $status->Ok;

  $Q->addmessage($status,"Polling backend")
    if $Q->verbose;

  # First make sure that the index parameter has not been changed
  # from under us. If it has we need to synch up and possibly
  # stop the queue. Only want to do this if the parameter
  # was changed not if the internal index has changed.
  check_index_param_sync( $status );

  # Poll the queue
  my ($pstat, $be_status, $message) = $Q->queue->backend->poll;

  # Update the DRAMA parameters
  # Do this before checking the status because we want to make
  # sure that everything is up-to-date before we trigger FAILURE
  # responses since some of these routines clear FAILURE parameter
  update_contents_param($status);
  update_index_param($status);
  update_status_param($status);
  update_alert_param(0, $status);

  # If pstat is false (perl bad status), set status to bad
  # If be_status is bad also set status to bad.
  # Stop the queue in both cases, report the errors but then
  # carry on using good status
  if (!$pstat) {
    # Poll failure
    DRAMA::ErsPush();
    $Q->addmessage( Dits::APP_ERROR, "Error polling the backend - queue will be stopped");
    my $lstat = new DRAMA::Status;
    &STOPQ($lstat);

    # Did we get a reason
    my $r = $Q->queue->backend->failure_reason;
    if ($r) {
      $Q->addmessage( 0, "A reason for the polling failure was supplied.");
      # Did get a reason. Does it help?
      # Need to convert the details to a SDS object
      my %details = $r->details;
      $details{INDEX} = $r->index;
      $details{REASON} = $r->type;

      print "detected a failure: " . Dumper(\%details) ."\n";

      set_failure_parameter( $lstat, %details );

      # dealt with it so clear the reason
      $Q->queue->backend->failure_reason(undef);
    }

    # Pop error stack
    DRAMA::ErsPop();
  } else {
    # Go through the messages and group them by status code to separate
    # good from bad. This allows the parameter updating to be slightly
    # more efficient since we can send multiple lines to addmessage() at once
    my $good = $Q->queue->backend->_good;
    my @stack;
    my $curstat = -1;
    for my $i (0..$#$be_status) {
      my $bestat = $be_status->[$i];
      my $bemsg  = $message->[$i];
      $bemsg = "Status bad without associated error message!"
        if (!defined $bemsg && $bestat != $good);

      # skip if we have no message defined in this slot by now.
      # it is possible if status is good
      next unless defined $bemsg;

      # Store messages in list each of which is an array ref with first element
      # the status and subsequent elements the messages
      if ($curstat == $bestat ) {
        push(@{$stack[-1]}, $bemsg);
      } else {
        $curstat = $bestat;
        push(@stack, [ $bestat, $bemsg]);
      }
    }

    # Need to go through the backend messages and check status on each
    my $err_found = 0;          # true if we have found an error
    for my $chunk (@stack) {
      my $bestat = shift(@$chunk);
      if ($bestat != $good && !$err_found) {
        # if this is the first bad status
        # we have found an error
        $err_found = 1;
        $Q->addmessage($bestat, "Stopping the queue due to backend error");
        &STOPQ( $status, Queue::Constants::QSTATE__BCKERR );
      }
      $Q->addmessage( $bestat, @$chunk);
    }
  }

  # Need to reschedule polltime seconds
  Jit::DelayRequest( $Q->polltime, $status);

  #  print Dumper($status) . "\nSTATUS: ".$status->GetStatus . "\n";

  #  Jit::ActionExit( $status );
  return $status;
}

# This routine kicks the POLLing and forces it to stop rescheduling
# itself

sub KICK_POLL {
  my $status = shift;
  return $status unless $status->Ok;
  $Q->addmessage($status, "Kicked poll - ending");
  Dits::PutRequest(Dits::REQ_END, $status);
  return $status;
}


=item B<GETENTRY>

Retrieves a specific entry from the queue using the specified
index position. The index is specified as "Argument1".

The Sds structure returned by this action has a key "ENTRY"
containing the hash form of the entry. For a SCUBA ODF this
is simply keyword/value pairs that form the ODF itself.

Usually used to force a new target into an entry in conjunction
with REPLACEQ.

Note that there is no C<SETTARG> action.

=cut

sub GETENTRY {
  my $status = shift;
  Jit::ActionEntry( $status );
  return $status unless $status->Ok;

  croak "Not yet generic";

  my $arg = Dits::GetArgument( $status );
  my $index = $arg->Geti( "Argument1", $status );

  if ($status->Ok) {
    print "Request for index $index\n";

    my $entry = $Q->queue->contents->getentry($index);

    if ($entry) {
      # Need to change the interface so we have a "asHash" method.
      my %odf = $entry->entity->odf;

      # Add entries as strings
      my $sds = Sds->PutHash( \%odf, "ENTRY", $status);
      print Dumper($sds);
      Dits::PutArgument($sds, Dits::ARG_COPY,$status);
      Jit::ActionExit($sds, $status);
      return $status;
    } else {
      # set status to bad
      $status->SetStatus( Dits::APP_ERROR);
      $status->ErsRep(0, "Specified index [$index] not present in queue");
    }
  } else {
    # Did not even get an argument
    $status->ErsRep(0, "Must supply a queue position to GETENTRY");
  }
  Jit::ActionExit( $status );
  return $status;
}

=item B<MSBCOMPLETE>

This action sends a doneMSB or rejectMSB to the OMP database
if the corresponding entries can be found in the completion
data structure.

Sds Argument contains a structure with a completion key which must match
the key published by the queue (present in the MSBCOMPLETE
parameter) pointing to:

  COMPLETE   - tri-valued  0 - reject +ve - accept MSB
               -ve - remove MSB without action "took no data"
  USERID     - user associated with this request [optional]
  REASON     - String describing any particular reason

There can be more than one pending MSB entry so we can trigger
multiple MSBs at once (this will be the case if we have been
running the queue without a monitor GUI).

Alternatively, for ease of use at the command line we also support

  Argument1=CompletionKey Argument2=complete 
  Argument3=userid Argument4=reason

=cut

sub MSBCOMPLETE {
  my $status = shift;
  Jit::ActionEntry( $status );
  return $status unless $status->Ok;

  $Q->addmessage($status,"Running MSB COMPLETE action.")
    if $Q->verbose;

  # argument is a boolean governing whether or not we should
  # mark the MSB as done or not
  my $arg = Dits::GetArgument( $status );

  # Tie to a hash
  my %sds;
  tie %sds, 'Sds::Tie', $arg;

  print Dumper( \%sds );

  my @completed;
  if (exists $sds{Argument1}) {
    # We have numbered args
    push(@completed, { compkey => $sds{Argument1},
                       complete => $sds{Argument2},
                       userid => $sds{Argument3},
                       reason => $sds{Argument4},
                     });
  } else {
    # We have transid args
    for my $key (keys %sds) {
      # see if we have a hash ref
      next unless ref($sds{$key}) eq 'HASH';
      push(@completed, {
                        compkey => $key,
                        complete => $sds{$key}->{COMPLETE},
                        userid => $sds{$key}->{USERID},
                        reason => $sds{$key}->{REASON},
                       });

    }

  }

  print "Processed arguments:\n";
  print Dumper(\@completed);

  if (!@completed) {
    $status->SetStatus(Dits::APP_ERROR);
    $status->ErsRep(0,"Attempting to mark MSB as completed but can not find any arguments to the action");
    $Q->addmessage($status,"Attempting to mark MSB as completed but can not find any arguments to the action");
    return $status;
  }

  # Now loop over all the transids
  for my $donemsb (@completed) {

    # First get the MSBID and PROJECTID
    my %details = $Q->get_msbcomplete_parameter_transid( $status,$donemsb->{compkey});

    my $projectid = $details{PROJECTID};
    my $msbid     = $details{MSBID};
    my $msb       = $details{MSB};
    my $msbtid    = $details{MSBTID};

    print "ProjectID: ".(defined $projectid ? $projectid : "<undef>") .
      " MSBID: ".(defined $msbid ? $msbid : "<undef>").
        " Transaction: ". (defined $msbtid ? 
                           $msbtid : "<undef>").
                             "\n";

    # Ooops if we have nothing
    if (!$donemsb->{compkey}) {
      $Q->addmessage($status,"Attempting to mark MSB as complete but insufficient information supplied!");
      next;
    } elsif (!$msbid || !$projectid) {
      $Q->addmessage($status,"Attempting to mark MSB with completion key ".$donemsb->{compkey}." as complete but can no longer find it in the parameter system.");
      next;
    }

    my $mark = $donemsb->{complete};
    my $martxt;
    if ($mark == 0) {
      $martxt = 'REJECT';
    } elsif ($mark > 0) {
      $martxt = 'ACCEPT';
    } elsif ($mark < 0) {
      $martxt = 'IGNORE';
    } else {
      $martxt = 'UNKNOWN';
    }
    $Q->addmessage($status,"Attempting to mark MSB with completion key ".$donemsb->{compkey}." (transaction $msbtid) as complete [$martxt]");

    if ($mark > 0) {

      try {
        my $msg;
        # Need to mark it as done [unless we are in simulate mode]
        if ($Q->simdb) {
          # Simulation so do nothing
          $msg = "[in simulation without modifying the DB]";
        } else {
          # Reality - blank message and update DB
          # SOAP message
          use SOAP::Lite;
          my $msbserv =  new SOAP::Lite();

          $msbserv->uri('http://www.eao.hawaii.edu/OMP::MSBServer');

          $msbserv->proxy(
              OMP::Config->getData('omp-private') .
                  OMP::Config->getData('cgidir') . '/msbsrv.pl',
              timeout => 6);

          $msg = '';
          # You can not use a SOAP call from within a DRAMA callback
          # since they both share the same alarm system. You will find that
          # you get instant timeouts even though the message is sent
          # correctly. We either need to revert to using the native
          # perl method calls (Which we used in the past but ran into
          # problems when OMP systems got out of sync, especially if 
          # MSBID calculation changes)
          # Sometimes the MSB acceptance takes a long time and we also
          # do not want to hang the queue during this. Use a short timeout
          # which always fails.
          eval {
            $msbserv->doneMSB($projectid, $msbid, $donemsb->{userid},
                              $donemsb->{reason}, $msbtid);
          };
          $Q->addmessage($status, "Got bit by timeout bug in ACCEPT: $@")
            if $@;
        }
        $Q->addmessage($status,
                       "MSB marked as done for project $projectid $msg");
      } otherwise {
        # Big problem with OMP system
        my $E = shift;
        $status->SetStatus( Dits::APP_ERROR );
        $status->ErsRep(0,"Error marking msb $msbid as done: $E");
        $Q->addmessage($status, "Error marking msb $msbid as done: $E");
      };

    } elsif ($mark == 0) {
      # Reject the MSB

      try {
        # file a comment to indicate that the MSB was rejected
        # unless we are in simulation mode
        my $msg;
        if ($Q->simdb) {
          $msg = "[in simulation without modifying the DB]";
        } else {
          $msg = '';
          # This can be a local call since MSBID is not recalculated
          OMP::MSBServer->rejectMSB( $projectid, $msbid, $donemsb->{userid},
                                     $donemsb->{reason}, $msbtid);
        }
        $Q->addmessage($status,"MSB rejected for project $projectid $msg");

      } otherwise {
        # Big problem with OMP system
        my $E = shift;
        $status->SetStatus( Dits::APP_ERROR );
        $status->ErsRep(0,"Error marking msb $msbid as rejected: $E");
        $Q->addmessage($status, "Error marking msb $msbid as rejected: $E");
      };

    } else {
      $Q->addmessage($status,
                     "Removing MSB without notifying OMP database [took no data]");
    }

    # Return if we have bad status
    if (!$status->Ok) {
      Jit::ActionExit( $status );
      return $status;
    }

    # and clear the parameter
    $Q->clear_msbcomplete_parameter( $status, $donemsb->{compkey} );

    # And remove the MSB from the queue
    if ($msb) {
      $Q->addmessage($status, "Removing completed MSB from queue");
      $Q->cutmsb( $msb );
    }

  }
  Jit::ActionExit( $status );
  return $status;
}

=back

=begin __PRIVATE__

=head1 Internal Routines

These internal routines are used to simplify the individual actions by
grouping shared code. They are not in a stand-alone module simply
because the only program that currently needs these routines is this
program. They do not form part of the public interface.

=over 4

=item Sds_to_Entry

Converts an SDS structure into an array of C<Queue::Entry>
objects suitable for placing on the queue.

  @entries = Sds_to_Entry( $argid );

Currently assumes that the XML file name is in the sds structure
as Argument1.

An optional argument can be used to indicate that the entries
correspond to CAL observations and should not be grouped
as MSBs. Default is to group into MSBs.

  @entries = Sds_to_entry( $argid, $iscal );

=cut

my $QUEUE_ID = 0;
sub Sds_to_Entry {
  my $argId = shift;
  my $iscal = shift;

  return unless defined $argId;

  # Need to check that we have a structure
  $argId->List(new DRAMA::Status);

  # tie the argId to a perl Hash
  my %sds;
  tie %sds, 'Sds::Tie', $argId;

  # Need to parse the XML
  my (@entries) = readXML( $sds{Argument1} );

  # Associate them with an MSB object
  # Note that this constructor associates itself with each
  # entry and so will not be destroyed when this $msb goes
  # out of scope.
  # If we are calibrations we do not want an MSB associations
  unless ($iscal) {
    # The MSB might have cal project IDs in it so first
    # find the non-cal project ID
    my $projectid;
    for my $e (@entries) {
      $projectid = $e->projectid;
      last if $projectid !~ /CAL/i;
    }
    my $msb = new Queue::MSB( entries => \@entries,
                              projectid => $projectid,
                              msbid => $entries[0]->msbid,
                              msbtitle => $entries[0]->msbtitle(),
                            );

    # Register a completion handler
    $msb->msbcomplete( \&msbtidy );

    # Increment the global queue ID
    $QUEUE_ID++;

    # Store the Queue ID
    $msb->queueid( $QUEUE_ID );

  } else {
    # for queue id of 0
    for my $ent (@entries) {
      $ent->queueid( 0 );
    }
  }

  untie $argId;
  return @entries;
}


# PARAMETER MANIPULATION

=item B<update_contents_param>

Update the CONTENTS parameter

  update_contents_param( $status );

=cut

sub update_contents_param {
  return unless $_[0]->Ok;

  # Read the QUEUE parameter
  my $sdp = $Q->_params;
  my $sds = $sdp->GetSds('Queue',$_[0]);
  return undef unless defined $sds;

  #$sds->List($_[0]);

  # Read the current queue contents
  # Note that the current contents will return an array containing
  # however many entries there are rather than the number of Queue
  # entries we have reserved
  my @Cur_contents = $Q->queue->contents->stringified;

  # Compare the current contents with the sds structure
  my $upd_con = compare_sds_to_perl($sds, 'Contents', \@Cur_contents, $_[0]);

  # If either of the update flags are true we should update
  my $update = 0;
  $update = 1 if $upd_con;

  # Notify the parameter system
  $sdp->Update($sds,$_[0]) if $update;

  # Clear any failure reasons if we have changed the Entries
  clear_failure_parameter($_[0]) if $update;

  # Check for the current value on the queue
  update_current_param($_[0]);

  # Update the time remaining
  update_time_remaining( $_[0] );

}

=item B<update_status_param>

Update the Stopped/Running flag using the STATUS parameter.

  update_status_param( $status );

The status argument is the DRAMA inherited status and not the
queue status.

=cut

sub update_status_param {
  my $status = shift;
  return unless $status->Ok;

  # Read the status parameter
  my $sdp = $Q->_params;
  my $state = $sdp->GetString('STATUS',$status);

  # Read whether the Queue is running
  my $running = $Q->queue->backend->qrunning;

  # Only change the parameter if needed
  if ($state eq 'Running' && !$running) {
    $sdp->PutString('STATUS','Stopped',$status);
  } elsif ($state eq 'Stopped' && $running) {
    $sdp->PutString('STATUS','Running',$status);
  }

}

=item B<update_alert_param>

Make sure the alert parameter is ok.

  update_alert_param( $isalert, $status );

If first argument is true, the ALERT parameter is set to this
value. If it is false it is reset.

=cut

sub update_alert_param {
  my $alert = shift;
  my $status = shift;
  return unless $status->Ok;

  # Read the Alert parameter
  my $sdp = $Q->_params;
  my $state = $sdp->Geti('ALERT',$status);

  $alert = 0 if !defined $alert;
  # Only change the parameter if needed
  if ( ($alert && !$state) || 
       (!$alert && $state)) {
    $sdp->Puti("ALERT", $alert, $status );
  }

}

=item B<update_index_param>

Sync the index parameter with the queue

  update_index_param( $status );

=cut

sub update_index_param {
  my $status = shift;
  return unless $status->Ok;

  # Read the index parameter
  my $sdp = $Q->_params;
  my $index = $sdp->Geti('INDEX',$status);

  # Get the queue value
  my $curindex = $Q->queue->contents->curindex;

  # Currently the parameter defaults to 0 if there are no entries
  $curindex = 0 unless defined $curindex;

  # Only change the parameter if needed
  if ($index != $curindex) {
    #print "::--+-+-+-+ SYNC index [$index/$curindex]\n";
    $sdp->Puti('INDEX', $curindex, $status);

    # Remember to change the local perl version. This lets
    # us know when the parameter was changed by external command
    $Q->_local_index( $curindex );

    # Update the time remaining
    update_time_remaining( $status );

  }

}

=item B<update_time_remaining>

Update the time remaining parameter.

  update_time_remaining( $status );

=cut

sub update_time_remaining {
  my $status = shift;
  return unless $status->Ok;

  # Read the time parameter
  my $sdp = $Q->_params;
  my $time = $sdp->Geti('TIMEONQUEUE',$status);

  # Get it from the queue
  my $qtime = int($Q->queue->contents->remaining_time->minutes);

  if ($qtime != $time) {
    $sdp->Puti( 'TIMEONQUEUE', $qtime, $status);
  }

}

=item B<verify_time_remaining>

Check whether the time remaining on the queue exceeds a set
threshold. Sets bad status (in place) if the threshold is exceeded.

  verify_time_remaining( $status );

The threshold is set to 40 minutes.

If the current observation is the last observation in the queue
the time remaining is not checked. This is to allow MSBs to be stacked
before the long observation completes.

=cut

sub verify_time_remaining {
  my $status = shift;
  return unless $status->Ok;

  # Check to see if we are the last observation
  my $curindex = $Q->queue->contents->curindex;
  my $maxindex = $Q->queue->contents->maxindex;

  return if defined $curindex && defined $maxindex
    && $curindex == $maxindex;

  # Set the threshold
  my $TIME_THRESHOLD = 40.0;

  my $qtime = int($Q->queue->contents->remaining_time->minutes);

  if ($qtime > $TIME_THRESHOLD) {
    $status->SetStatus( Dits::APP_ERROR );
    $status->ErsRep(0, "The time remaining on the queue ($qtime minutes) exceeds the allowed threshold of $TIME_THRESHOLD. Please try again when the queue is smaller.");
  }

}


=item B<check_index_param_sync>

See if the queue index and parameter have changed independently
The LOCAL_INDEX variable helps us with this since we know it
can not be changed by an external prompt.

  check_index_param_sync( $status );

The correct way to do this may be to set up an internal monitor
on the parameter itself.

=cut

sub check_index_param_sync {
  my $status = shift;
  return unless $status->Ok;

  # Read the status parameter
  my $sdp = $Q->_params;
  my $index = $sdp->Geti('INDEX',$status);

  # Get the queue value
  my $curindex = $Q->queue->contents->curindex;

  # Currently undef is not supported as a parameter value
  # so we change it to 0
  $curindex = 0 unless defined $curindex;

  # This means we should change the queue value if they are different
  # and if the parameter is not equal to the local cache
  # it is possible for the current index to be different to the 
  # parameter since the queue is updated asynchronously
  if ($index != $curindex && $index != $Q->_local_index) {
    #print "+_+_+_+_+ Stopping queue due to index change [$index/$curindex]\n";
    $Q->_local_index( $index );
    $Q->queue->contents->curindex( $index );
    &STOPQ( $status );
    # Always clear if we have tweaked something
    clear_failure_parameter($status);

    # Update the time remaining
    update_time_remaining( $status );

  }

}

=item B<update_current_param>

Update the CURRENT parameter.

  update_current_param( $status );

The details of the entry currently being observed are obtained
via the global Queue object.

=cut

sub update_current_param {
  return unless $_[0]->Ok;

  # Read the CURRENT parameter
  my $sdp = $Q->_params;
  my $curr = $sdp->GetString('CURRENT', $_[0]);

  # Read the last_sent to the backend
  my $last_sent = $Q->queue->backend->last_sent;

  # If nothing on set now to 'None'
  my $now;
  if (defined $last_sent) {
    $now = $last_sent->string;
  } else {
    $now = 'None';
  }

  # Compare
  if ($now ne $curr) {
    $sdp->PutString('CURRENT',$now,$_[0]);
  }

}

=item B<clear_failure_parameter>

Clear the contents of the failure parameter.
Arguments: inherited status

  clear_failure_parameter( $status );

=cut

sub clear_failure_parameter {
  my $status = shift;
  return unless $status->Ok;

  # Read the FAILURE parameter
  my $sdp = $Q->_params;
  my $sds = $sdp->GetSds('FAILURE',$status);
  return undef unless defined $sds;

  # Now need to look for the DETAILS object
  # (use a private status)
  my $lstat = new DRAMA::Status;

  # it seems we have to trigger the update after the Sds structure
  # has been freed
  my $updated;
  {
    my $detsds = $sds->Find("DETAILS", $lstat);

    if ($detsds) {
      # if we have a DETAILS object we need to
      # configure it so that it is deleted when it goes out of scope
      $detsds->flags(1,1,1);

      $updated = 1;
    }
  }

  # and update the parameter
  $sdp->Update($sds,$status) if $updated;

  return;
}

=item B<set_failure_parameter>

Set the contents of the failure parameter.
Arguments: Inherited status, information hash

  set_failure_parameter( $status, %reason);

=cut

sub set_failure_parameter {
  my $status = shift;
  return unless $status->Ok;

  # Read the FAILURE parameter
  my $sdp = $Q->_params;
  my $sds = $sdp->GetSds('FAILURE',$status);
  return undef unless defined $sds;

  # Read the arguments
  my %details = @_;

  # KLUGE - currently GetSds blesses the Sds into Arg class
  # This breaks PutHash since it *must* work on Sds objects
  # in order for the correct Create to be called. I think this
  # means that at the very leasy Sds.pm needs to use SUPER::Create
  # rather than just the Arg Create method. For now we rebless
  bless $sds, "Sds";

  # Add entries as strings
  $sds->PutHash( \%details, "DETAILS", $status);

  #$sds->List($status);

  # Notify the parameter system
  $sdp->Update($sds,$status);

  return;
}

=item B<compare_sds_to_perl>

Sub to compare an SDS array with a perl array, updating the SDS array
if necessary. Arguments are an sds structure, the name of the
component in that structure that is to be compared, reference to a
reference perl array and inherited status:

  $changed = compare_sds_to_perl( $sdsid, $name, \@comp, $status);

Returns true if they were different, otherwise returns false.
This is used to decide whether a DRAMA parameter should have its
update state triggered for remote monitors (rather than sending
a monitor trigger every time we may have changed the Perl array).

=cut

sub compare_sds_to_perl ($$$$) {
  die 'Usage: compare_sds_to_perl($sds,$name,$arref,$status)'
    unless (scalar(@_) == 4 && ref($_[2]) eq 'ARRAY'
            && UNIVERSAL::isa($_[0],'Sds'));

  return unless $_[3]->Ok;

  my $sds = shift;
  my $name = shift;
  my $arr = shift;

  # Read the named item from the Sds component
  my $csds = $sds->Find($name,$_[0]);
  my @sds_contents = $csds->GetStringArray($_[0]);

  # Process this array to remove trailing spaces (padding)
  # and shorten the array to match the size of the first
  # empty string - this will make the comparison more robust
  for my $i (0..$#sds_contents) {
    $sds_contents[$i] =~ s/\s+$//;
    if ($sds_contents[$i] eq '') {
      $#sds_contents = $i - 1;
      last;
    }
  }

  # This flag is used ro report a difference
  # Start by assuming no difference
  my $cur_diff = 0;

  # Since we have tidied the original array we can compare number of entries
  # directly
  # Making sure we remember that it is possible for the array to have
  # more than NENTRIES in it.
  if (scalar(@$arr) <= NENTRIES && scalar(@sds_contents) != scalar(@$arr)) {
    # Different number of elements
    $cur_diff = 1;
  } else {
    # Step through the current contents and compare with the
    # parameter contents
    for my $i (0..$#sds_contents) {
      # Need to retrieve the current value and trim
      # it if it is longer than the size of the SDS array
      # Take null character into account
      my $current = $arr->[$i];
      $current = substr($current,0,$Q->maxwidth()-1)
        if length($current) >= $Q->maxwidth;

      # Also need to trim trailing space
      $current =~ s/\s+$//;
	
      # Now compare the sds and current entries
      if ($sds_contents[$i] ne $current) {
        $cur_diff = 1;
        last;
      }
    }
  }

  # Update the Contents array if they are different
  $csds->PutStringArrayExists($arr, $_[0]) if $cur_diff;

  # Return the cur_diff flag - true if we have updated
  return $cur_diff;
}



=item B<msbtidy>

This is the callback when the MSB queue finishes or if an MSB has been
cut whilst some of it has been observed.  all it needs to do is
extract the MSBID and set the completion parameter Passed either an
entry object or a C<Queue::MSB> object

=cut

sub msbtidy {
  my $object = shift;

  # Return immediately if we have no object
  return unless defined $object;

  # create a new drama status
  my $status = new DRAMA::Status;

  # What we really need is the Queue::MSB object so that we can
  # remove the MSB entries from the queue when it has been marked
  # as complete
  my $msb;
  if (UNIVERSAL::isa($object, "Queue::MSB")) {
    $msb = $object;
  } elsif (UNIVERSAL::isa($object,"Queue::Entry")) {
    $msb = $object->msb;
  } else {
    croak "Unable to determine class of the object supplied to msbtidy\n";
  }

  $Q->addmessage($status, "MSB contents fully observed");

  # If the MSB has not been observed at all then we do not
  # need to trigger anything here
  if ($msb && ! $msb->hasBeenObserved) {
    return;
  }

  # Since we are already processing an MSBCOMPLETE
  # we do not want to trigger another one
  # so disable the completion
  $msb->hasBeenObserved( 0 ) if $msb;

  # Get the MSB ID project ID from the MSB object
  # if possible
  my ($projectid, $msbid, $msbtitle);
  if ($msb) {
    $projectid = $msb->projectid;
    $msbid = $msb->msbid;
    $msbtitle = $msb->msbtitle();
  } else {
    # try the entry
    $projectid = $object->projectid;
    $msbid = $object->msbid;
    $msbtitle = $object->msbtitle();
  }

  # Collect the information we need to send the qmonitor
  # The REQUEST key is not really required since we never
  # set REQUEST to 0
  my %data;
  $data{REQUEST} = 1;
  $data{MSB}     = $msb;
  $data{QUEUEID} = $msb->queueid;
  $data{QUEUEID} = 0 unless defined $data{QUEUEID};

  # if we do not have an MSBID and project then we cant do anything else
  # so do not change the parameter
  if ($msbid && $projectid) {

    if ($projectid eq 'SCUBA' || $projectid =~ /CAL$/ ) {
      $Q->addmessage($status, "Completed 'calibration' observations. No doneMSB");
      $Q->addmessage($status, "Project ID was $projectid");

    } elsif ($projectid eq 'UNKNOWN') {
      $Q->addmessage($status, "Unable to determine project ID. No doneMSB");

    } else {

      $Q->addmessage($status, "Possibility of marking MSB for project $projectid as done [MSB=$msbid TID=".
                     $msb->transid."]");

      # Store it
      $data{MSBID} = $msbid;
      $data{PROJECTID} = $projectid;
      $data{TIMESTAMP} = time(); # so that the gui can report the completion time
      $data{MSBTITLE} = $msbtitle if $msbtitle;

      # And now store it in the parameter
      $Q->set_msbcomplete_parameter($status, %data);

    }

  } else {
    my $msg = "Queue contents fully observed but no MSBID or PROJECTID available.";
    $Q->addmessage($status, $msg)
  }
}

=item B<queue_empty>

Callback to use when the queue enters an empty state. The alert parameter
is set to EMPTY.

=cut

sub queue_empty {
    # Register a empty-queue handler
  update_alert_param( Queue::Constants::QSTATE__EMPTY, new DRAMA::Status);
}

=item B<_pending_msb_filename>

Retrieve the name of the filename being used for the pending MSB information.
This will be read on runup to see if any MSBs are pending. It will be written
every time MSBs are ready for acceptance and removed if no MSBs are pending.

  $filename = $Q->_pending_msb_filename();

Temporary directory is returned if the primary directory does not exist.

Only one queue is allowed to run on any system so no attempt is made to lock
the filename to a unique host (else another program would need to know the host
to find out pending MSBs).

=cut

{
  my $DEFAULTDIR = "/jcmtdata/orac_data";
  my $DEFAULTNAME = "pending_msb_accepts.dat";
  my $FNAME;
  sub _pending_msb_filename {
    if (!defined $FNAME) {
      if (-d $DEFAULTDIR) {
        $FNAME = File::Spec->catfile( $DEFAULTDIR, $DEFAULTNAME );
      } else {
        $FNAME = File::Spec->catfile( File::Spec->tmpdir, $DEFAULTNAME );
      }
    }
    return $FNAME;
  }
}

=back

=end __PRIVATE__


=head1 AUTHOR

Tim Jenness E<lt>t.jenness@jach.hawaii.eduE<gt>.

Copyright (C) 2002-2006 Particle Physics and Astronomy Research Council.
Copyright (C) 2007 Science and Technology Facilities Council.
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
