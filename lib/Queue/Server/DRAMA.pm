package Queue::Server::DRAMA;

=head1 NAME

Queue::Impl::DRAMA - Implementation of a queue server task using DRAMA

=head1 SYNOPSIS

  use Queue::Server::DRAMA;

  $Q = new Queue::Server::DRAMA( nentries => 250, simdb => 1 );
  $Q->mainloop();

=head1 DESCRIPTION

DRAMA code required to implement basic DRAMA-based queue as a DRAMA
task.

Things that need to be tidied up:

  - QUEUEID [currently shared lexical]
      + Should really be determined by the queue but this requires
        that an Entry
  - MSBComplete hash [shared lexical]
      + Could be part of this object directly or use a hasa
        relationship for the hash and provide a little wrapper object
  - What to do about MSBTidy
      + It calls an update_param function so clearly needs to know
        about drama. Everything else is actually generic and could go
        in a base class but that won't work because we are passing around
        just the code ref.
  - Do we put the callbacks in their own package?
  - [RELATED] Location of TRANS_DIR

I don't think we can associate this object directly with the callbacks
at this time.

=cut

use strict;
use warnings;
use Carp;
use Jit;
use DRAMA;

use Queue::MSB;
use Queue::EntryXMLIO qw/ readXML /;

use OMP::MSBServer;
use OMP::Info::Comment;
use OMP::Error qw/ :try /;

use vars qw/ $VERSION /;
$VERSION = '0.01';

# Default parameters
# These control the number of entries in the DRAMA parameter
# and the length of each line.
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
is false.

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
  my $flag = 0;  # Not spawnable
  DRAMA::ErsPush();
  my $status = new DRAMA::Status;

  Dits::DperlPutActions("STARTQ",     \&STARTQ,  undef,$flag,undef,$status);
  Dits::DperlPutActions("STOPQ",      \&STOPQ,   undef,$flag,undef,$status);
  Dits::DperlPutActions("LOADQ",      \&LOADQ,  undef,$flag,undef,$status);
  Dits::DperlPutActions("ADDBACK",    \&ADDBACK,  undef,$flag,undef,$status);
  Dits::DperlPutActions("ADDFRONT",   \&ADDFRONT,  undef,$flag,undef,$status);
  Dits::DperlPutActions("INSERTQ",    \&INSERTQ,  undef,$flag,undef,$status);
  Dits::DperlPutActions("CLEARQ",     \&CLEARQ,    undef,$flag,undef,$status);
  Dits::DperlPutActions("POLL",       \&POLL,\&KICK_POLL,$flag,undef,$status);
  Dits::DperlPutActions("REPLACEQ",   \&REPLACEQ,undef,$flag,undef,$status);
  Dits::DperlPutActions("EXIT",       \&EXIT,    undef,0,undef,$status);
  Dits::DperlPutActions("GETENTRY",   \&GETENTRY,    undef,0,undef,$status);
  Dits::DperlPutActions("CLEARTARG",  \&CLEARTARG,    undef,0,undef,$status);
  Dits::DperlPutActions("MSBCOMPLETE",\&MSBCOMPLETE,    undef,0,undef,$status);
  Dits::DperlPutActions("CUTQ",       \&CUTQ,    undef,0,undef,$status);
  Dits::DperlPutActions("CUTMSB",     \&CUTMSB,    undef,0,undef,$status);
  Dits::DperlPutActions("SUSPENDMSB", \&SUSPENDMSB, undef,0,undef,$status);
  Dits::DperlPutActions("DONEMSB",    \&DONEMSB, undef,0,undef,$status);

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

=item MESSAGES

An SDS structure containing a string array of lines with interesting
messages from the observing system whilst observing the current entry
and also a corresponding integer status.

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
  $sdp->Create("INDEX","INT",0);
  $sdp->Create("TIMEONQUEUE","INT",0);
  $sdp->Create("CURRENT","STRING",'None');

  my $queue_sds = Sds->Create("Queue",undef,Sds::STRUCT,0,$status);
  $queue_sds->Create("Contents",undef,Sds::CHAR,
		     [$maxwidth,$nentries],$status);

  # This contains any information on ODFs that need more information
  my $failure_sds = Sds->Create("FAILURE",undef, Sds::STRUCT,0,$status);

  # This contains queue completion triggers
  my $msbcomplete_sds = Sds->Create("MSBCOMPLETED",undef, Sds::STRUCT,0,
				    $status);

  # Create message parameter. Includes a status and a message
  # 50 lines of 132 characters per line
  my $msglen = 132;
  my $msgnum = 50;
  my $msg_sds = Sds->Create("MESSAGES",undef, Sds::STRUCT,0,$status);
  $msg_sds->Create("MESSAGE", undef, Sds::CHAR,[$msglen,$msgnum],$status);
  $msg_sds->Create("STATUS",undef,Sds::INT,0,$status);

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
  $sdp->Create('','SDS',$msg_sds);

  # Have to make sure that these SDS objects don't go out of scope
  # and destroy their contents prior to use in the parameter system
  # Can either put them in a hash inside $self OR simply prevent them
  # from being freed. Cache them for now
  $self->_param_sds_cache( $queue_sds, $failure_sds, $msbcomplete_sds,
			 $msg_sds );


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

  $Q->queue( new Queue::SCUCD );
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

=cut

sub addmessage {
  my $self = shift;
  my ($msgstatus, $msg) = @_;

  # trap for DRAMA status
  if (UNIVERSAL::can($msgstatus, "GetStatus")) {
    # extract the value of the status
    $msgstatus = $msgstatus->GetStatus;
  }

  # split messages on new lines
  my @lines = split(/\n/,$msg);

  # Create a new error context
  DRAMA::ErsPush();
  my $status = new DRAMA::Status;

  # Retrieve the parameter system
  my $sdp = $self->_params;

  if (!defined $msgstatus) {
    Carp::cluck("msgstatus not defined");
  }

 # print "Status Y: ". $status->GetStatus ."\n";

  # We really want to use the JIT parameters for monitoring
  # so that we integrate properly into the OCS. The problem
  # is that the Jit_ErsOut routines are only called when we
  # are in user interface context.
  if ($msgstatus == DRAMA::STATUS__OK) { # STATUS__OK
    # Send back through normal channels
    # problem here is that we do not want to do this if this
    # is a user interface context because then Jit will also
    # intercept this and attach it to a parameter!
    # Would be nice to send it to STDOUT if we are in user interface
    # context so that we can log if everything is acting up.
    Dits::UfaceCtxEnable(sub {use Data::Dumper;print Dumper(\@_);}, $status);
    DRAMA::MsgOut($status, $msg);
    Dits::UfaceCtxEnable(undef, $status);
    # Simple "good" messages go in a simple parameter
#    $sdp->PutString( 'JIT_MSG_OUT', $msg, $status);
    print "MsgOut: $msg\n";
  } else {
    # bad status so we have to populate JIT_ERS_OUT
    # with values of MESSAGE, FLAGS and STATUS
    my $sds = $sdp->GetSds('JIT_ERS_OUT', $status);
    if ($status->Ok) {
      my $msgsds = $sds->Find('MESSAGE',$status);
      if ($status->Ok) {
	my $stsds = $sds->Find('STATUS',$status);
	my $fsds = $sds->Find('FLAGS',$status);
	use PDL::Lite;
	$msgsds->PutStringArrayExists(\@lines,$status);

	if ($status->Ok) {
	  # need a status and flag per line of message
	  my @flags = map { 0 } @lines;
	  my @msgstati = map { $msgstatus } @lines;
	  $stsds->PutPdl(PDL::Core::pdl(\@msgstati));
	  $fsds->PutPdl(PDL::Core::pdl(\@flags));

	  # Trigger update in parameter system
	  print "------- TRIGGERING UPDATE [$msgstatus] with ".
	    join("\n",@lines)."\n";
	  $sdp->Update($sds,$status);
	}
      }
    }
  }

  unless ($status->Ok) {
    warn "Error populating message parameters:". $status->ErrorText;
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

Start the queue.

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
  clear_failure_parameter($_[0]);
  Jit::ActionExit( $_[0] );
  return $_[0];
}

=item B<STOPQ>

Stop the queue from sending any more entries to the backend.

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

Clear the queue and load the specified ODFs onto it.
Accepts a single argument that specifies the ODF file
name of the ODF macro name. See C<Sds_to_Entry>.

=cut

sub LOADQ {
  my $status = shift;
  Jit::ActionEntry( $status );
  return $status unless $status->Ok;

  $Q->addmessage( $status, "Running LOADQ") if $Q->verbose;

  my $argId = Dits::GetArgument;

  # If no argument simply return
  return unless defined $argId;

  # Extract the ODF entries from the argument
  my @entries = &Sds_to_Entry( $argId );

  $Q->queue->contents->loadq( @entries );

  # Always clear if we have tweaked something
  clear_failure_parameter($status);


#  print Dumper($grp);
#  print Dumper(\@entries);
#  print Dumper($Q->queue);
#  print "Found " . scalar(@entries) . " ODFs\n";

  Jit::ActionExit( $status );
  return $status;
}


=item B<ADDBACK>

Add the supplied ODFs to the back of the queue.
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
  return $status unless defined $argId;

  # Retrieve the ODF entries associated with the args
  my @entries = &Sds_to_Entry($argId);

  if ($#entries > -1) {
    # Add these entries to the back of the queue
    $Q->queue->contents->addback(@entries);

    # Update the DRAMA parameters
    update_contents_param($status);

  }
  Jit::ActionExit( $status );
  return $status;
}

=item B<ADDFRONT>

Add the supplied ODFs to the front of the queue.
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
  return $status unless defined $argId;

  # Retrieve the ODF entries associated with the args
  my @entries = &Sds_to_Entry($argId);

  if ($#entries > -1) {
    # Add these entries to the back of the queue
    $Q->queue->contents->addfront(@entries);

    # Update the DRAMA parameters
    update_contents_param($status);

  }
  Jit::ActionExit( $status );
  return $status;
}


=item B<INSERTQ>

Insert calibration ODFs into the queue at the current highlight
or at the specified index. Note that these calibrations are not
treated as MSBs.

ODFs are specified in the same way as for C<LOADQ>.

The optional index can be specified as "Argument2".

=cut

sub INSERTQ {
  my $status = shift;
  Jit::ActionEntry( $status );
  return $status unless $status->Ok;

  $Q->addmessage( $status, "Running INSERTQ") if $Q->verbose;

  my $argId = Dits::GetArgument;

  # If no argument simply return
  return unless defined $argId;

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

  # Always clear if we have tweaked something
  clear_failure_parameter($status);


#  print Dumper($grp);
#  print Dumper(\@entries);
#  print Dumper($Q->queue);
#  print "Found " . scalar(@entries) . " ODFs\n";

  Jit::ActionExit( $status );
  return $status;
}

=item B<REPLACEQ>

Replace an entry on the queue with another. This action takes three
arguments. An index specifying the location in the queue to place the
new entry, the ODF specification itself (as a filename), and a logical
indicating whether source information from this ODF should be
propagated to following entries. The arguments can either be specified
by number ("Argument1" for the index and "Argument2" for the file name
and "Argument3" for the source propagation flag) or by name (INDEX and
PROPSRC, all remaining SDS entries used to construct a single ODF
directly).

The status of the entry matches that of the one it replaces
ie whether it is the first or last obs in an MSB. It is automatically
associated with the MSB of the entry it is replacing.

=cut

sub REPLACEQ {
  my $status = shift;
  Jit::ActionEntry( $status );
  return $status unless $status->Ok;

  croak "Not implemented in generic manner\n";

  $Q->addmessage( $status, "Running REPLACEQ") if $Q->verbose;

  my $argId = Dits::GetArgument;

  # If no argument simply return
  return unless defined $argId;

  # tie the argId to a perl Hash
  $argId->List($status);
  my %sds;
  tie %sds, 'Sds::Tie', $argId;

  print Dumper(\%sds);

  my ($index, $odf, $propsrc);
  if (exists $sds{INDEX}) {
    $index = $sds{INDEX};
    $propsrc = $sds{PROPSRC};
    my %copy = %sds;
    delete $copy{INDEX};
    delete $copy{PROPSRC};
    $odf = new SCUBA::ODF(Hash => \%copy );
    print "Reading via ODF hash\n";

  } elsif (exists $sds{Argument1}) {
    $index = $sds{Argument1};
    my $odffile = $sds{Argument2};
    $odf = new SCUBA::ODF( File => $odffile );
    $propsrc = $sds{Argument3};
  }

  # Get the old entry
  my $old = $Q->queue->contents->getentry($index);

  # should set bad status on error
  # Create a new entry
  #my $entry = new Queue::Entry::SCUBAODF("X", $odf);
  my $entry;
  # Replace the old entry
  $Q->queue->contents->replaceq( $index, $entry );

  # if we are propogating source information we need to do it now
  $Q->queue->contents->propsrc($index, $odf->getTarget)
    if $propsrc;

  # Always clear if we have tweaked something
  clear_failure_parameter($status);
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

  $status->SetStatus( Dits::APP_ERROR );
#  $status->ErsRep(0,"Test error");
#  $Q->addmessage($status, "Test error message");
  $status->ErsRep(0,"Test error");

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
    $Q->addmessage($status, "No action - must supply a position to cut");
    return $status;
  }

  # Retrieve the INDEX and NCUT integers from the Args
  my %sds;
  tie %sds, 'Sds::Tie', $argId;

  print Dumper(\%sds);

  my ($index, $ncut);
  if (exists $sds{INDEX}) {
    $index = $sds{INDEX};
    $ncut = $sds{NCUT};
  } elsif (exists $sds{Argument1}) {
    $index = $sds{Argument1};
    $ncut = $sds{Argument2};
  } else {
    $Q->addmessage($status,"Unable to determine cut position");
    return $status;
  }
  $ncut = 1 unless defined $ncut;

  $Q->addmessage($status,"Removing $ncut observation[s] starting from index $index");

  # CUT
  $Q->queue->contents->cutq($index, $ncut);

  # Update the DRAMA parameters
  update_contents_param($status);
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
  return unless defined $argId;

  # Retrieve the INDEX integer from the Args
  my %sds;
  tie %sds, 'Sds::Tie', $argId;

  print Dumper(\%sds);

  my $index;
  if (exists $sds{INDEX}) {
    $index = $sds{INDEX};
  } elsif (exists $sds{Argument1}) {
    $index = $sds{Argument1};
  }


  # Make sure there are entries in the queue
  return $status unless defined $Q->queue->contents->countq;

  $Q->queue->contents->cutmsb($index);
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
    $Q->addmessage($status, "Suspend MSB attempted but no entries in queue");
    return $status;
  }

  # then ask the entry for the MSBID, ProjectID and ObsLabel
  # these should be methods of the entry but for now
  # we assume the "entity" has them
  my $proj = $entry->projectid;
  my $msbid = $entry->msbid;
  my $label = $entry->entity->getObsLabel;

  if ($proj && $msbid && $label) {
    # Suspend the MSB unless we are in simulate mode
    OMP::MSBServer->suspendMSB($proj, $msbid, $label)
	unless $Q->simdb;

    $Q->addmessage($status, "MSB for project $proj has been suspended at the current observation");

    # Now need to cut the MSB without triggering accept/reject
    my $msb = $entry->msb;
    if (defined $msb) {
      $msb->hasBeenObserved(0);
    }

    # and cut it
    $Q->queue->contents->cutmsb( $Q->queue->contents->curindex );

  } else {
    $Q->addmessage($status, "Attempted to suspend MSB but was unable to determine either the label, projectid or MSBID from the current entry");
  }
  Jit::ActionExit( $status );
  return $status;
}

=item B<DONEMSB>

Mark the MSB as done [relies on the MSB entry being active] that is
associated with the currently highlighted position.

Not clear that this has any additional functionality over CUTMSB since
we do not want to mark it done if it has not been observed at all and
we would probably like to be asked about it.

This action should be used with caution since it will always mark the
MSB as complete if it can obtain the project ID and MSBID from the
entry, regardless of whether it has been observed. This action
needs to be reviewed.

=cut

sub DONEMSB {
  my $status = shift;
  Jit::ActionEntry( $status );
  return $status unless $status->Ok;

  # first get the current entry
  my $entry = $Q->queue->contents->curentry;
  unless ($entry) {
    $Q->addmessage($status, "Explicit 'done MSB' attempted but no entries in queue");
    return $status;
  }

  $Q->addmessage($status, "doneMSB currently not supported. Pending review");
  return $status;

  # then ask the entry for the MSBID and projectID
  # these should be methods of the entry but for now
  # we assume the "entity" has them
  my $proj = $entry->projectid;
  my $msbid = $entry->msbid;

  if ($proj && $msbid) {

    if ($proj =~ /SCUBA|JCMTCAL|UKIRTCAL/) {
      $Q->addmessage($status, "Can not mark a standard calibration as complete");
    } else {
      # Only mark as done if we are in live mode
      try {
	OMP::MSBServer->doneMSB($proj, $msbid)
	    unless $Q->simdb;

	$Q->addmessage($status, "MSB for project $proj has been marked as completed");
      } otherwise {
	# Big problem with OMP system
	my $E = shift;
	$status->SetStatus( Dits::APP_ERROR );
	$status->ErsRep(0,"Error marking msb $msbid as done: $E");
	$Q->addmessage($status, "Error marking msb $msbid as done: $E");

      };
      return $status unless $status->Ok;

    }

  } else {
    $Q->addmessage($status, "Attempted to mark an MSB as complete but was unable to determine either the projectid or MSBID from the current entry");
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

  # If pstat is false, set status to bad
  # If be_status is bad also set status to bad.
  # Stop the queue in both cases, report the errors but then
  # carry on using good status
  if (!$pstat) {
    DRAMA::ErsPush();
    my $lstat = new DRAMA::Status;
    $lstat->SetStatus(Dits::APP_ERROR);
    $lstat->ErsOut(0,"Error polling the backend [status = $pstat] - Queue stopped");

    # Did we get a reason
    my $r = $Q->queue->backend->failure_reason;
    if ($r) {
      # Did get a reason. Does it help?
      # Need to convert the details to a SDS object
      my %details = $r->details;
      $details{INDEX} = $r->index;
      $details{REASON} = $r->type;

      use Data::Dumper;
      print "detected a failure: " . Dumper(\%details) ."\n";

      set_failure_parameter( $lstat, %details );

      # dealt with it so clear the reason
      $Q->queue->backend->failure_reason(undef);
    }

    # error so we must stop the queue. Note that since lstat has
    # been flushed this now corresponds to a good status.
    &STOPQ($lstat);
    DRAMA::ErsPop();
  } else {
    # Need to go through the backend messages and check status on each
    my $good = $Q->queue->backend->_good;
    my $err_found = 0; # true if we have found an error
    for my $i (0..$#$be_status) {
      my $bestat = $be_status->[$i];
      my $bemsg  = $message->[$i];
      if ($bestat == $good) {
	$Q->addmessage( $bestat, $bemsg) if defined $bemsg;
      } else {
	# We have an error from the backend itself
	# We need to file the message and stop the queue
	if (!$err_found) {
	  # we have found an error
	  $err_found = 1;

	  DRAMA::ErsPush();
	  my $lstat = new DRAMA::Status;
	  $lstat->SetStatus(Dits::APP_ERROR);
	  $lstat->ErsOut(0,
			 "Error from queue backend task - Stopping the queue");
	  &STOPQ( $lstat );
	  DRAMA::ErsPop();
	  $Q->addmessage($bestat, "Stopping the queue due to backend error");
	}
	# Send the message
	$bemsg = "Status bad without associated error message!"
	  unless defined $bemsg;
	$Q->addmessage($bestat, $bemsg);
      }
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

Sds Argument contains a structure with a timestamp key (which must be
recognized by the system [ie in the completion parameter]) pointing
to:

  COMPLETE   - logical (doneMSB or rejectMSB)
  USERID     - user associated with this request [optional]
  REASON     - String describing any particular reason

There can be more than one timestamp entry so we can trigger
multiple MSBs at once (this will be the case if we have been
running the queue without a monitor GUI).

Alternatively, for ease of use at the command line we also support

  Argument1=timestamp Argument2=complete 
  Argument3=userid Argument4=reason

=cut

sub MSBCOMPLETE {
  my $status = shift;
  Jit::ActionEntry( $status );
  return $status unless $status->Ok;

  $Q->addmessage($status,"MSB COMPLETE")
    if $Q->verbose;

  # argument is a boolean governing whether or not we should
  # mark the MSB as done or not
  my $arg = Dits::GetArgument( $status );

  # Tie to a hash
  my %sds;
  tie %sds, 'Sds::Tie', $arg;

  use Data::Dumper;
  print Dumper( \%sds );

  my @completed;
  if (exists $sds{Argument1}) {
    # We have numbered args
    push(@completed, { timestamp => $sds{Argument1},
		       complete => $sds{Argument2},
		       userid => $sds{Argument3},
		       reason => $sds{Argument4},
		     });
  } else {
    # We have timestamp args
    for my $key (keys %sds) {
      # see if we have a hash ref
      next unless ref($sds{$key}) eq 'HASH';
      push(@completed, {
			timestamp => $key,
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

  # Now loop over all the timestamps
  for my $donemsb (@completed) {

    # First get the MSBID and PROJECTID
    my %details = get_msbcomplete_parameter_timestamp( $status,$donemsb->{timestamp});

    my $projectid = $details{PROJECTID};
    my $msbid     = $details{MSBID};
    my $msb       = $details{MSB};

    print "ProjectID: $projectid MSBID: $msbid TimeStamp: ".
      $donemsb->{timestamp}."\n";

    # Ooops if we have nothing
    if (!$msbid || !$projectid) {
        $Q->addmessage($status,"Attempting to mark MSB with timestamp ".$donemsb->{timestamp}." as complete but can no longer find it in the parameter system.");
	next;
    }

    my $mark = $donemsb->{complete};

    $Q->addmessage($status,"Attempting to mark MSB with timestamp ".$donemsb->{timestamp}." as complete Mark=$mark");

    if ($mark) {

      try {
	# Need to mark it as done [unless we are in simulate mode]
	OMP::MSBServer->doneMSB($projectid, $msbid, $donemsb->{userid},
			      $donemsb->{reason})
	    unless $Q->simdb;

	$Q->addmessage($status,"MSB marked as done for project $projectid");
      } otherwise {
	# Big problem with OMP system
	my $E = shift;
	$status->SetStatus( Dits::APP_ERROR );
	$status->ErsRep(0,"Error marking msb $msbid as done: $E");
	$Q->addmessage($status, "Error marking msb $msbid as done: $E");
      };

    } else {

      try {
	# file a comment to indicate that the MSB was rejected
	# unless we are in simulation mode
	OMP::MSBServer->rejectMSB( $projectid, $msbid, $donemsb->{userid},
				   $donemsb->{reason})
	    unless $Q->simdb;

	$Q->addmessage($status,"MSB rejected for project $projectid");
      } otherwise {
	# Big problem with OMP system
	my $E = shift;
	$status->SetStatus( Dits::APP_ERROR );
	$status->ErsRep(0,"Error marking msb $msbid as rejected: $E");
	$Q->addmessage($status, "Error marking msb $msbid as rejected: $E");
      };

    }

    # Return if we have bad status
    if (!$status->Ok) {
      Jit::ActionExit( $status );
      return $status;
    }

    # and clear the parameter
    clear_msbcomplete_parameter( $status, $donemsb->{timestamp} );

    # And remove the MSB from the queue
    if ($msb) {
      $Q->addmessage($status, "Removing completed MSB from queue");

      # Get an entry from the MSB
      my $entry = $msb->entries->[0];

      # Convert to an index
      if ($entry) {
	my $index = $Q->queue->contents->getindex( $entry );
	if (defined $index) {
	  # Cut it
	  $Q->queue->contents->cutmsb( $index );
	}
      }
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

Currently assumes that the macro odf file name is in the sds structure
as Argument1. Can not yet accept the ODF itself as an SDS structure.

An optional argument can be used to indicate that the ODFs
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
    my $msb = new Queue::MSB( entries => \@entries,
			      projectid => $entries[0]->projectid,
			      msbid => $entries[0]->msbid,
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
    &STOPQ($status);
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

=item B<set_msbcomplete_parameter>

Set the contents of the MSB complete parameter.

Arguments: Inherited status, information hash 

This method takes the data (a hash of information that should be sent
to the monitoring system), timestamps it and places it into the
parameter. Use C<clear_msbcomplete_parameter> to remove it. This
allows us to stack up MSB completion requests if we do not have a
qmonitor running.

  set_msbcomplete_parameter( $status, %details)

Note that the MSB key is treated as a special case (the relevant
Queue::MSB object) and is not stored directly in the parameter.

=cut

my %MSBComplete;
sub set_msbcomplete_parameter {
  my $status = shift;
  return unless $status->Ok;

  # Read the MSBCOMPLETED parameter
  my $sdp = $Q->_params;
  my $sds = $sdp->GetSds('MSBCOMPLETED',$status);
  return undef unless defined $sds;

  # Read the arguments
  my %details = @_;

  print Dumper(\%details);
  print ($status->Ok ? "status ok\n" : "status bad\n");

  # Generate a timestamp (not that it really needs to be
  # unique since Sds will handle it if we keep on adding
  # identical entries but they are hard to remove)
  my $tstamp = time();

  # The MSB object should not go in the SDS structure
  # so we store all this information in a hash outside
  # of it [that only the *_msbcomplete functions use -
  # this is essentially a Queue::MSBComplete object
  # Take a copy
  $MSBComplete{$tstamp} = { %details };

  # Remove the MSB field
  delete $details{MSB};

  # Add it to the parameter
  # standard kluge
  bless $sds, "Sds";

  # put in the inormation
  $sds->PutHash( \%details, "$tstamp", $status);

  $sds->List($status);

  # Notify the parameter system
  $sdp->Update($sds,$status);

  print "Get to the end of qcompleted param setting\n";
  return;
}

=item B<clear_msbcomplete_parameter>

Remove the completed information from the DRAMA parameter.

 clear_msbcomplete_parameter($status, $timestamp);

=cut

sub clear_msbcomplete_parameter {
  my $status = shift;
  return unless $status->Ok;

  # Read the MSBCOMPLETED parameter
  my $sdp = $Q->_params;
  my $sds = $sdp->GetSds('MSBCOMPLETED',$status);
  return undef unless defined $sds;

  my $tstamp = shift;

  # Now need to look for the timestamp object
  # (use a private status)
  my $lstat = new DRAMA::Status;

  # Have to remove the old entries
  my $updated;
  {
    my $detsds = $sds->Find("$tstamp", $lstat);

    if ($detsds) {
      # if we have a DETAILS object we need to
      # configure it so that it is deleted when it goes out of scope
      $detsds->flags(1,1,1);

      # We are going to destroy it
      $updated = 1;

    }

  }

  # And we need to trigger a parameter update notification
  # if it was changed
  $sdp->Update($sds, $status) if $updated;

  # Clear the hash entry
  delete $MSBComplete{$tstamp};

  return;
}

=item B<get_msbcomplete_parameter_timestamp>

Retrieve the MSBID and Projectid information associated with the
supplied timestamp.  Simply returns the hash entry in %MSBComplete (the
pseudo C<Queue::MSBComplete> object)

 %details = get_msbcomplete_parameter_timestamp($status,$tstamp);

=cut

sub get_msbcomplete_parameter_timestamp {
  my $status = shift;
  return unless $status->Ok;
  my $tstamp = shift;

  if (exists $MSBComplete{$tstamp}) {
    return %{ $MSBComplete{$tstamp} };
  } else {
    return ();
  }

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

  # Now get the projectid and msbid
  my $projectid = $object->projectid;
  my $msbid = $object->msbid;

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

      $Q->addmessage($status, "Possibility of marking MSB for project $projectid as done [MSB=$msbid]");

      # Store it
      $data{MSBID} = $msbid;
      $data{PROJECTID} = $projectid;

      # And now store it in the parameter
      set_msbcomplete_parameter($status, %data);

    }

  } else {
    my $msg = "Queue contents fully observed but no MSBID or PROJECTID available.";
    $Q->addmessage($status, $msg)
  }
}


=back

=end __PRIVATE__


=head1 AUTHOR

Tim Jenness E<lt>t.jenness@jach.hawaii.eduE<gt>.

Copyright (C) 2002-2003 Particle Physics and Astronomy Research Council.
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
