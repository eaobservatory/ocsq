package Tk::OCSQMonitor;

=head1 NAME

Tk::OCSQMonitor - MegaWidget for monitoring an OCS Queue

=head1 SYNOPSIS

  use Tk::OCSQMonitor;

  my $w = $MW->OCSQMonitor(
                           -qtask => 'OCSQUEUE',
                           -qwidth => 110,
                           -qheight => 10,
                           -msgwidth => 100,
                           -msbcompletecb => \&msbcomplete,
                           -user => \$userid,
                          );

=head1 DESCRIPTION

A Tk Widget for monitoring and controlling an OCS Queue (see
L<ocsqueue>) that can be embedded into a larger Tk GUI.

Consists of 3 panes:

 - Queue contents and highlighting
 - Informational messages from the queue
 - Error messages from the queue

A status panel reporting the time remaining on the queue, the
entry that is currently being observed and whether the queue
is running or stopped.

Buttons for stopping, starting and clearing the queue and for disposing
or suspending MSBs.

=head1 ATTRIBUTES

The following options can be set when the widget is constructed:

=over 4

=item B<-msbcompletecb>

Callback to be invoked when the widget receives notification that the
MSBCOMPLETED parameter has been modified. Called with the current
widget as first argument, reference to a scalar holding the OMP ID of
the current user and reference to a hash of MSB completion information
(with timestamps as keys). Can be called with an empty hash (since the
update triggers when the parameter is cleared). This can be used to
remove a widget when a second monitor has accepted the MSB. A default
method is provided that will pop up a tabbed notebook allowing
detailing each MSB.

A reference to the user ID is passed in so that it can be modified in
the callback.

=item B<-user>

A reference to a scalar variable that should contain a valid OMP user
ID. The content of this variable will be updated as the widget is used
so that you can share this variable with other widgets that may need
to know a user ID. The widget constructor will abort if a reference
is not provided. If no user is specified, this configure option will
be undefined until a point at which the user id is needed by the
widget, in which case a reference to a scalar will be associated with
this item.

=back

=head1 SUBROUTINES

=over 4

=cut

use strict;
use warnings;
use Carp;
use Tk;
use Term::ANSIColor qw/ colored /;
use Tk::TextANSIColor;
use File::Spec;
use Data::Dumper;

use Astro::Catalog;
use Astro::Coords;
use Astro::Telescope;
use Tk::AstroCatalog;
use Astro::SourcePlot qw/ sourceplot /;
use JAC::OCS::Config::TCS::BASE;
use JAC::Audio;

use OMP::General;
use OMP::DateTools;
use OMP::UserServer;

# We use DRAMA but we assume the queue gui is initialising DRAMA
use Queue::JitDRAMA;
use Queue::Control::DRAMA;
use Queue::Constants;
use FindBin;

use Time::Piece qw/ gmtime /;
use Time::Seconds qw/ ONE_HOUR /;

our $AUDIO_DIR = File::Spec->catdir($FindBin::RealBin,"audio");

use vars qw/ $VERSION /;

use base qw/ Tk::Derived Tk::Frame /;
Construct Tk::Widget 'OCSQMonitor';


sub Populate {
  # Read the base widget and the supplied arguments
  my ($w, $args) = @_;

  # Provide defaults for width and height
  my %def = ( -qwidth => 110, -qheight => 10, -msgwidth => 100 );

  # Default for msbcomplete callback
  $def{'-msbcompletecb'} = \&respond_to_qcomplete;

  # merge with supplied arguments
  %$args = ( %def, %$args );

  croak "Must supply a queue name [qtask]"
    unless exists $args->{'-qtask'};

  croak "If supplying a user ID string, it must be a reference"
    if exists $args->{-user} && ref($args->{'-user'}) ne 'SCALAR';

  # Configure options
  $w->ConfigSpecs( -qtask => ['PASSIVE'],
                   -qwidth => ['PASSIVE'],
                   -qheight => ['PASSIVE'],
                   -msgwidth => ['PASSIVE'],
                   -user => ['PASSIVE'],
                   -msbcompletecb => ['PASSIVE'],
                 );

  # Generic widget options
  $w->SUPER::Populate($args);

  # Copy args to configure options
  # [although the widget constructor should do this itself and indeed
  # seems to when I try to update the value of -user in the Populate
  # routine - the value is overwritten with that provided on the command
  # line]
  $w->configure('-qtask' => $args->{'-qtask'});
  $w->configure('-qwidth' => $args->{'-qwidth'});
  $w->configure('-qheight' => $args->{'-qheight'});
  $w->configure('-msgwidth' => $args->{'-msgwidth'});
  $w->configure('-msbcompletecb' => $args->{'-msbcompletecb'});
  $w->configure('-user' => $args->{'-user'});

  # Get the internal hash data
  my $priv = $w->privateData();

  # Associate ourselves with the remote control of the named queue
  $priv->{QCONTROL} = new Queue::Control::DRAMA( $args->{'-qtask'} );

  # Create three frames in top level
  # Dont pack them until we are ready

  my $Fr1 = $w->Frame;
  my $Fr2 = $w->Frame;
  my $Fr3 = $w->Frame;
  my $Fr4 = $w->Frame;

  # Make sure it is deleted correctly
  $w->OnDestroy( [ '_shutdown', $w]);

  # Exit button
  # Default state of queue button
  $priv->{TOGGLE} = '---';

  # Create a hash for the monitor returns. Must set it here so that we are not
  # dependent on a new monitor trashing our tie
  $priv->{MONITOR} = {};

  #update_status 'Creating buttons',75;
  #$Fr3->Button( -text => 'EXIT', -command => \&shutdown)->pack(-side => 'left');
  $Fr3->Button( -textvariable => \$priv->{TOGGLE},
                -width => 10,
                -command => sub { $w->_toggleq(); },
              )->pack(-side => 'left');
  $Fr3->Button( -text => 'CLEAR',
                -command => sub { $priv->{QCONTROL}->clearq }
              )->pack(-side => 'left');
  $Fr3->Button( -text => 'DISPOSE MSB',
                -command => sub { $priv->{QCONTROL}->cutmsb }
              )->pack(-side => 'left');

  #  $Fr3->Button( -text => 'SUSPEND MSB',  -command => \&suspendmsb)->pack(-side => 'left');

  # Create a label for Queue status
  $Fr1->Label(-text => 'Queue Status:')->grid(-row => 0,-column=>0,-sticky=>'w');
  my $Qstatus = $Fr1->Label(-textvariable => \$priv->{MONITOR}->{STATUS},
                           )->grid(-row=>0,-column=>1,-sticky=>'w');


  # We must be allowed to access the Q status widget
  $w->Advertise( '_qstatus' => $Qstatus);

  # Label for current entry information
  $Fr1->Label(-text => 'Current entry:')->grid(-row => 3,-column=>0,-sticky=>'w');
  my $CurrStatus = $Fr1->Label(-textvariable => \$priv->{MONITOR}->{CURRENT},
                              )->grid(-row=>3,-column=>1,-sticky=>'w');

  # Time remaining on the queue
  $Fr1->Label(-text => 'Time on Queue (minutes):')->grid(-row => 4,-column=>0,-sticky=>'w');
  my $TimeOnQueue = $Fr1->Label(-textvariable => \$priv->{MONITOR}->{TIMEONQUEUE},
                               )->grid(-row=>4,-column=>1,-sticky=>'w');


  # Create listbox in frame 2
  $Fr2->Label(-text => 'Queue contents')->pack(-side => 'top');


  my $ContentsBox = $Fr2->Scrolled('Text',
                                   -scrollbars => 'e',
                                   -wrap => 'none',
                                   -height => $args->{'-qheight'},
                                   -width  => $args->{'-qwidth'},
                                   #		 -state  => 'disabled',
                                  )->pack(-side=> 'top', -expand => 1, -fill => 'both');

  $ContentsBox->bindtags(qw/widget_demo/); # remove all bindings but dummy "widget_

  # We must be allowed to access the Q status widget
  $w->Advertise( '_qcontents' => $ContentsBox);

  # Setup a Text widget that will take all the output sent to MsgOut
  $priv->{MORE_INFO} = 0;           # is the window visible
  $priv->{MORE_DISPLAYED_ONCE} = 0; # Has it been visible at least once?

  my $MsgBut = $Fr4->Checkbutton(-variable => \$priv->{MORE_INFO},
                                 -text     => 'Info messages...',
                                 -command => [ 'show_info', $w ],
                                );

  my $MsgText = $Fr4->Scrolled('TextANSIColor',-scrollbars=>'w',
                               -height=>16,
                               -width=>$args->{'-msgwidth'},
                               -background => 'black',
                               -foreground => 'white',
                              );
  BindMouseWheel($MsgText);

  $priv->{MORE_ERS} = 0;
  my $ErsBut = $Fr4->Checkbutton(-variable => \$priv->{MORE_ERS},
                                 -text     => 'Error messages...',
                                 -command => ['show_ers', $w],
                                );

  my $ErsText = $Fr4->Scrolled('TextANSIColor',-scrollbars=>'w',
                               -height=>8,
                               -width=>$args->{'-msgwidth'},
                               -background => 'black',
                               -foreground => 'white',
                              );
  BindMouseWheel($ErsText);

  # Pack into frame four - note that the show_info method displays the Msg and ErsText widgets
  $MsgBut->grid(-row=>0, -column=>1, -sticky=>'w');
  $ErsBut->grid(-row=>2, -column=>1, -sticky=>'w');

  # Set weights
  $Fr4->gridRowconfigure(1, -weight => 2);
  $Fr4->gridRowconfigure(3, -weight => 1);
  $Fr4->gridColumnconfigure(1, -weight => 1);


  # Advertise the messages and error text widgets
  $w->Advertise( 'messages' => $MsgText);
  $w->Advertise( 'errors' => $ErsText );


  # Force visibility
  $priv->{MORE_INFO} = 1;
  $w->show_info();

  $priv->{MORE_ERS} = 1;        # Force display
  $w->show_ers();

  # print information to this text widget
  my $status = new DRAMA::Status;
  Dits::UfacePutMsgOut( sub {
                          $w->write_text_messages( 'messages', @_ );
                        },
                        $status);

  # Also want this to appear in the log file so just print it
  Dits::UfacePutErsOut( sub {
                          my $flag = shift;
                          # make sure that we prepend with # marks in the DRAMA style
                          my $done_first;
                          print "<<<<<<<<<<<>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>.\n";
                          my @hashed = map {
                            my $hash = " ";
                            if (!$done_first) {
                              $hash = "#";
                              $done_first = 1;
                            }
                            "#". $hash . $_;
                          } @_;
                          print "$_\n" for @hashed;
                          $w->write_text_messages( 'errors', @hashed );
                        },
                        $status);


  # These variables record whether or not we have an active monitor
  # configured. 0 = we are running, 1 = it has been cancelled somehow
  $priv->{QUEUE_CANCELLED} = 1;

  # Kick them off for 30 second repeat
  $w->check_monitors(30);

  # Finally, pack frames into top frame
  $Fr1->grid(-row => 0, -column =>0, -sticky=>'w');
  $Fr2->grid(-row => 1, -column =>0, -sticky=>'ewns', -columnspan=>2);
  $Fr3->grid(-row => 2, -column =>0);
  $Fr4->grid(-row => 3, -column =>0, -sticky=>'ewns',-columnspan=>2);

  # And configure the grid weighting for resize events
  $w->gridRowconfigure( 3, -weight => 2 );
  $w->gridRowconfigure( 1, -weight => 1 );
  $w->gridColumnconfigure( 1, -weight => 1 );

  return;
}

# Callback triggered when the widget is destroyed
sub _shutdown {
  my $w = shift;
  my $priv = $w->privateData;

  # Need to release the monitor (unless that has been done already)
  if (exists $priv->{MONITOR}->{MONITOR_ID} ) {

    if (exists $priv->{MONITOR}->{MONITOR_ID} && ! $priv->{QUEUE_CANCELLED}) {
      monitor($w->cget('-qtask'), "CANCEL", $priv->{MONITOR}->{MONITOR_ID});
    }
    select undef,undef,undef,0.1; # Wait for any shutdown messages
    DoDramaEvents;
  }
  # Need to clear the MsgOut and ErsOut tie
  Dits::UfacePutMsgOut( undef, new DRAMA::Status);
  Dits::UfacePutErsOut( undef, new DRAMA::Status);
  print "Closedown\n";
}

sub BindMouseWheel {
  my $w = shift;

  # Mousewheel binding from Mastering Perl/Tk, pp 370-371.
  if ($^O eq 'MSWin32') {
    $w->bind('<MouseWheel>' =>
             [ sub { $_[0]->yview('scroll', -($_[1] / 120) * 3, 'units') },
               Ev('D') ]
            );
  } else {
    $w->bind('<4>' => sub {
               $_[0]->yview('scroll', -3, 'units') unless $Tk::strictMotif;
             });
    $w->bind('<5>' => sub {
               $_[0]->yview('scroll', +3, 'units') unless $Tk::strictMotif;
             });
  }
}                               # end BindMouseWheel


# These routines relate to the handling of DRAMA monitors

# See if we have monitors setup, connecting if we do not
# Given that it takes a finite time for the monitor to attach
# and for the CANCELLED variable to be changed, we should ensure
# that we do not check the monitors more often than necessary
# Reschedules itself. This is a widget method.

#   $w->check_monitors( $MW, $time);

# The second argument specifies the rescheduling time in seconds.
# defaulting to 60

sub check_monitors {
  my ($w, $time) = @_;

  my $priv = $w->privateData;

  # The queue monitor
  if ($priv->{QUEUE_CANCELLED}) {
    $w->init_queue_monitor;
  }

  # Reschedule
  $time = 60 unless (defined $time && $time > 0); # seconds

  # convert to milliseconds
  my $ms =  1000 * $time;

  # Set up the after
  $w->after( $ms, ["check_monitors",$w, $time] );
  return;
}

# Write informational messages to the named widget
# Must be either 'errors' or 'messages'

sub write_text_messages {
  my $mega = shift;
  my $widname = shift;

  # Retrieve the MsgText widget
  my $w = $mega->Subwidget( $widname );
  return unless defined $w;

  # Support a reference to an array of lines or a simple list
  # containing text.
  my @lines;
  if (ref($_[0])) {
    @lines = @{ $_[0] };
  } else {
    @lines = @_;
  }

  # clean up the array
  _clean_array(\@lines);

  # Get private state data
  my $priv = $mega->privateData;

  # [CODE taken from the TIEHANDLE for Tk::Text - I wrote
  # it anyway]
  # Find out whether 'end' is displayed at the moment
  # Retrieve the position of the bottom of the window as
  # a fraction of the entire contents of the Text widget
  my $yview = ($w->yview)[1];

  # If $yview is 1.0 this means that 'end' is visible in the window
  # If the window has never been displayed yview will return 0
  # this means that we need to view the end unless the window
  # has been displayed 
  my $update = 0;
  $update = 1 if $yview == 1.0;

  # Force update to end if we have not yet been displayed
  $update = 1 unless $priv->{MORE_DISPLAYED_ONCE};

  # Insert the text
  $w->insert('end',join("\n",@lines)."\n");

  # Move to the end
  # Make sure that we do not move to the end if we can not see the end
  $w->see('end') if $update;

  return;
}

# Set up a monitor connection to the queue
# This is a widget method since the monitor messages are associated
# specifically with this GUI. This means that two widgets force two
# separate monitors

sub init_queue_monitor {
  my $w = shift;
  my $priv = $w->privateData();

  # Indicate whether the monitor has been cancelled
  $priv->{QUEUE_CANCELLED} = 0;

  $w->write_text_messages( 'messages', "Configuring Queue monitor" );

  # Setup the receiving hash but only if one does not already
  # exist [if one is already setup we should not trash it since that
  # may break GUI code that relies on automatic updates]
  $priv->{MONITOR} = {} unless exists $priv->{MONITOR};

  # initiate the monitor
  monitor($w->cget("-qtask"), "START", 
          "STATUS", "Queue", "CURRENT", "INDEX", "FAILURE","MSBCOMPLETED",
          "TIMEONQUEUE", "JIT_MSG_OUT", "JIT_ERS_OUT", "ALERT",
          {
           -monitorvar => $priv->{MONITOR},
           -sendcur    => 1,
           -repmonloss => 1,
           -complete   => sub { $w->write_text_messages('messages',"Monitor complete\n");
                                $priv->{QUEUE_CANCELLED} = 1;
                              },
           -info       => sub { print "Monitor INFO callback: $_[0]\n"},
           -cvtsub     => sub { $w->cvtsub(@_) },
           -error      => sub { $w->_monerror(@_) },
          });

}

# This routine withdraws or shows the MsgOut text widget
# depending on the value of $MORE_INFO.

sub show_info {
  my $mega = shift;             # The mega widget
  my $priv = $mega->privateData;
  my $w = $mega->Subwidget('messages');
  if ($priv->{MORE_INFO}) {
    # Span two columns so that grid weights can be applied
    $w->grid(-row=>1,-column=>1,-columnspan=>2,-sticky=>'nsew');
    # Indicate that we have been displayed at least once
    $priv->{MORE_DISPLAYED_ONCE} = 1;
  } else {
    $w->gridForget;
  }
}

# For Errors

sub show_ers {
  my $mega = shift;
  my $priv = $mega->privateData;
  my $w = $mega->Subwidget('errors');
  if ($priv->{MORE_ERS}) {
    # Span two columns so that grid weights can be applied
    $w->grid(-row=>3,-column=>1,-columnspan=>2,-sticky=>'nsew');
  } else {
    $w->gridForget;
  }
}


# Private functions

# This method "cleans" an array so that empty lines are removed
# from the end as well as trailing space. Used to convert SDS arrays
# to a usable perl array.
# Takes the array ref and modifies it in place.
# Does nothing if array reference is not defined
# Explicit undefs in the array are ignored

sub _clean_array {
  my $arr = shift;
  return unless defined $arr;
  @$arr = grep {defined $_ && /\w/} @$arr;
  foreach (@$arr) {
    s/\s+$//;
  }
}



# Convert subroutine - converts the parameter value
# to a value.
# For scalar parameters do nothing since generally those values
# are tied directly to widgets.

# For structured parameters we use this function to actually
# update the widget itself.

sub cvtsub {
  my ($w, $param, $value) = @_;

  #print "Received PARAMETER trigger: $param\n";
  my $priv = $w->privateData();

  if ($param eq 'STATUS') {
    my $Qstatus = $w->Subwidget( '_qstatus' );
    if ($value =~ /Stop/i) {
      $Qstatus->configure(-background=>'red',-foreground=>'black');
      $priv->{TOGGLE} = 'STARTQ';
      # beep
      #for (1..5) {print STDOUT "\a"; select undef,undef,undef,0.2}
    } else {
      $Qstatus->configure(-background=>'green',-foreground=>'black');
      $priv->{TOGGLE} = 'STOPQ';
    }
  } elsif ($param eq 'INDEX') {
    # Set the highlight position
    $w->update_index( $value );
  } elsif ($param eq 'JIT_MSG_OUT') {
    # Simple informational message
    print colored("$param:",'yellow') . "$value\n";
    $w->write_text_messages( 'messages', $value);

  } elsif ($param eq 'ALERT') {
    if (defined $value && $value > 0) {
      my $sound = "alert.wav";
      if ($value == Queue::Constants::QSTATE__BCKERR ) {
        $sound = "queuestoppederror.wav";
      } elsif ($value == Queue::Constants::QSTATE__EMPTY) {
        $sound = "queueisempty.wav";
      }
      _play_sound($sound);
    }
  }
  return $value if not ref($value);

  # Assume we have a Sds
  my %tie;
  tie %tie, "Sds::Tie", $value;
  #$value->List(new DRAMA::Status);
  if ($param eq 'Queue') {

    my %queue = %tie;

    # Strip trailing space and reduce array size
    #foreach (@{$queue{'Contents'}}) {
    #  s/\s+$//;
    #}

    # Update the Contents in the listbox
    # print "UPDATING QUEUE CONTENTS\n";
    $w->update_listboxes(\%queue);

    return \%queue;

  } elsif ($param eq 'FAILURE') {
    # When FAILURE triggers we should obtain the entry, see what the problem
    # is, pop up a gui to request help.
    # Problem is that you can not do this until the monitor has completed.
    # If you try to do an obey to retrieve the entry (if we decide not to publish
    # it as part of the FAILURE Sds parameter) you cannot use an "obeyw"
    # you can also not do any Tk event handling. The problem is the monitor
    # must complete before you go into any other event handling. This implies
    # that we have to set a variable from to indicate that FAILURE has returned
    # and then work that out when we enter the event loop. Easiest thing
    # is to do an after() for a few milliseconds later.

    print _param_log($param)."\n";
    print Dumper(\%tie);

    # if we are prompting for changes to the entry we
    # need to destroy that widget here because this may
    # indicate that someone else has responded or that another
    # problem is requested
    if ($priv->{FAIL_GUI}) {
      # Can not use the Exists method because we do not yet
      # treat this as a real Tk widget
      # print "Removing pre-existing FAIL_GUI\n";
      $priv->{FAIL_GUI}->destroy;
      undef $priv->{FAIL_GUI};
    }

    # first check that we have to react
    if (exists $tie{DETAILS}) {

      # Put up the failure GUI (usually the pointing selection)
      # Note that we can call this directly from this event
      # because this sub does not block waiting for a reponse
      # (unlike a DialogBox). You can not call a DRAMA obey
      # from a monitor trigger.
      # print "Creating a new FAIL_GUI\n";
      $w->respond_to_failure($tie{DETAILS});

    }

  } elsif ($param eq 'MSBCOMPLETED') {

    print _param_log($param)."\n";
    print Dumper(\%tie);

    # The parameter has been changed. Run the supplied callback.
    # By default this will put up a GUI with tabs asking to accept
    # or reject the MSB.
    if ($w->cget("-msbcompletecb")) {

      # If the value was not supplied we need to store a reference
      # to someother variable.
      my $userid = $w->cget('-user');

      if (!defined $userid) {
        my $null = '';
        $w->configure('-user', \$null);
        $userid = $w->cget('-user');
      }

      # Run callback
      $w->cget("-msbcompletecb")->($w,$userid,\%tie);

    } else {
      print "No registered callback for MSBCOMPLETED\n";
    }
  } elsif ($param eq 'JIT_ERS_OUT') {
    # $value->List(new DRAMA::Status);
    if (defined $tie{MESSAGE}) {
      my @lines = (ref $tie{MESSAGE} ? @{$tie{MESSAGE}} : ($tie{MESSAGE}));
      _clean_array(\@lines);
      chomp(@lines);
      print colored("$param:",'yellow') . "$_\n" for @lines;
    }
    $w->write_text_messages( 'errors', $tie{MESSAGE});

  } else {
    print colored("Unrecognized parameter $param\n",'yellow');
    print colored(Dumper(\%tie),"yellow");
  }
  #print "*********** Completed Monitor conversion [$param]\n";
  return $value;
}


sub _monerror {
  my $w = shift;
  my $priv = $w->privateData;
  # Flush status
  $_[2]->Flush;
  $priv->{QUEUE_CANCELLED} = 1;
}


# Start or stop the queue

sub _toggleq {
  my $w = shift;
  my $priv = $w->privateData;

  if (defined $priv && defined $priv->{MONITOR} &&
      defined $priv->{MONITOR}->{STATUS}) {
    if ($priv->{MONITOR}->{STATUS} =~ /^Stop/i) {
      #    print "Starting Q\n";
      $priv->{QCONTROL}->startq;
    } else {
      #    print "Stopping Q\n";
      $priv->{QCONTROL}->stopq;
    }
  }
}


# Subroutine to play a sound on the speaker. Do not test
# return value since it should be non-fatal if it fails
# See also OMP::Audio class
# Attempt to support OSX as well as esdplay
sub _play_sound {
  my $file = shift;
  print "PLAYING A SOUND ($file)\n";

  $file = File::Spec->catfile($AUDIO_DIR, $file);
  return unless -e $file;

  JAC::Audio::play( $file );
  return;
}

# Return formatted parameter prefix string
sub _param_log {
  my $param = shift;
  return colored("$param:",'yellow'). _tstamp();
}

# return a time stamp string to prepend to log messages
sub _tstamp {
  my $time = DateTime->now->set_time_zone( 'UTC' );
  return colored( $time->strftime("%T").":", "green");
}

sub update_listboxes {
  # Read the hash ref
  my $w = shift;
  my $href = shift;

  my $ContentsBox = $w->Subwidget('_qcontents');

  # Clear the contents listbox
  $ContentsBox->configure( -state => 'normal');
  $ContentsBox->delete('0.0','end');

  # Remove blank lines from the end of the array
  # Assume that all blank lines are bad
  my @contents = @{ $href->{Contents} };
  _clean_array( \@contents );

  # Fill it
  my $counter = 0;
  for my $line (@contents) {

    # Take local copy of index for callbacks
    my $index = $counter;

    # Generate the tag name based on the index
    my $dtag = "d" . $index;
    my $ctag = "c" . $index;

    # Get the reference position
    my $start = $ContentsBox->index('insert');

    # insert the line
    $ContentsBox->insert('end', sprintf("%-3d %s",$counter,$line) . "\n");

    # Remove all the tags at this position
    foreach my $tag ($ContentsBox->tag('names', $start)) {
      $ContentsBox->tag('remove', $tag, $start, 'insert');
    }

    # Create a new tag for the highlighter
    $ContentsBox->tag('add', $dtag, $start, 'insert');

    # and configure it 
    $ContentsBox->tag('configure', $dtag, 
                      #		      -foreground => 'white',
                      -background => 'green',);

    # Now create a new base color tag at higher priority
    # to control the general color. When a highlighter is added the
    # priorities will be raised and the highlighter will dominate
    $ContentsBox->tag('add',$ctag, $start, 'insert');

    # default foreground is black
    my $fgcol = 'black';
    if ($line =~ /SENT/) {
      $fgcol = 'yellow4';
    } elsif ($line =~ /OBSERVED/) {
      $fgcol = 'grey55';
    } elsif ($line =~ /ERROR/) {
      $fgcol = 'red';
    }

    # and configure it
    my $bgcol = "white";
    $ContentsBox->tag('configure', $ctag, 
                      -foreground => $fgcol,
                      -background => $bgcol,);

    # raise it
    $ContentsBox->tagRaise($ctag);

    # bind the tag to button click
    $ContentsBox->tag('bind', $dtag, '<ButtonRelease-1>' =>
                      sub {pset($w->cget('-qtask'),"INDEX", $index)});

    # and to the right mouse button
    $ContentsBox->tag('bind', $dtag, '<Button-2>' =>
                      [ \&ContentsMenu, $w, $index, Ev('X'), Ev('Y')] ,
                     );

    # show the user where there mouse is
    $ContentsBox->tag('bind', $ctag, '<Any-Enter>' =>
                      sub { shift->tag('configure', $ctag,
                                       -background => 'yellow',
                                       qw/ -relief raised
                                           -borderwidth 3 /); } );

    $ContentsBox->tag('bind', $ctag, '<Any-Leave>' =>
                      sub { shift->tag('configure', $ctag,
                                       -background => $bgcol,
                                       qw/ -relief flat /); } );


    $counter++;
  }

  $ContentsBox->configure( -state => 'disabled');

  # and finally insert the index
  my $priv = $w->privateData();
  $w->update_index( $priv->{MONITOR}->{INDEX} );

}


# Routine to update the position of the index.
#   $w->update_index( $index );
# Makes sure that the index is visible

sub update_index {
  my $w = shift;
  my $index = shift;

  # Get the sub widget that we need
  my $ContentsBox = $w->Subwidget('_qcontents');

  # First need to configure all the existing tags so that they
  # are not highlighted
  my %tags;
  foreach my $tag ($ContentsBox->tag('names')) {
    if ($tag =~ /^d\d/) {
      $ContentsBox->tagLower($tag);
    } elsif ($tag =~ /^c\d/) {
      $ContentsBox->tagRaise($tag);
    }
    # build up a hash of tag names so that we can guarantee
    # that the tag we use later actually exists
    $tags{$tag} = undef;
  }

  # only do something if we have a value
  if (defined $index) {
    my $dtag = "d" . $index;

    if (exists $tags{$dtag}) {
      # Now set the highlight
      $ContentsBox->tagRaise($dtag);

      # and make it visible.
      # see() has the problem that if the new index is close to the edge
      # it just displays the new index at the edge (so people can not see what
      # is coming up in the queue - they get to see what's already happened)
      # We therefore have to use yview()
      # (We decrement $index to make sure that we have a couple of lines visible
      # from the earlier part of the queue)
      $index--;
      $ContentsBox->yview("$index.0");
    }
  }
}

# This handles the middle mouse button click on the
# contents window
# Takes arguments of: widget, index number, Xpos, Ypos
# X and Y are usually calculated with
sub ContentsMenu {
  my $wid = shift;
  my $megawid = shift;
  my $index = shift;
  my $X = shift;
  my $Y = shift;

  my $priv = $megawid->privateData;
  my $Q = $priv->{QCONTROL};

  my $menu = $wid->Menu(-tearoff => 0,
                        -menuitems => [
                                       [
                                        "command" => "Modify observation $index",
                                        -command => sub { # do nothing
                                        },
                                        -state => 'disabled',
                                       ],
                                       "separator",
                                       ["command" => "Clear target index $index",
                                        -command => sub {
                                          $Q->cleartarg( $index );
                                        }
                                       ],
                                       ["command" => "Cut observation at index $index",
                                        -command => sub {
                                          $Q->cutq( $index, 1 );
                                        }],
                                       ["command" => "Cut MSB containing index $index",
                                        -command => sub {
                                          $Q->cutmsb( $index );
                                        }],
                                      ],
                       );
  #  $menu->Popup(-popover => "cursor");
  $menu->Post($X,$Y);
}



# GUI dealing with responding to a failure of an entry to load
# because it is missing information
# Arguments are: The entry, the failure details

sub respond_to_failure {
  my $w = shift;
  my $details = shift;

  # Get queue control object
  my $priv = $w->privateData();
  my $Q = $priv->{QCONTROL};

  #print Dumper($details);

  if ($details->{REASON} eq 'MissingTarget' ||
      $details->{REASON} eq 'NeedNextTarget' ) {

    # Create telescope object
    my $tel = new Astro::Telescope( $details->{TELESCOPE} );


    # First need to inform user of the request
    # (hopefully part of a single window)

    # Now create a catalog object

    # The choice of catalogue depends on the telescope, instrument and whether
    # we are a calibration observation or not.
    my $cat;

    if ($details->{TELESCOPE} eq 'JCMT') {

      # if we are a POINTING or FOCUS then we need the pointing catalog
      if ($details->{CAL}) {
        # We want calibrators only
        $cat = new Astro::Catalog;

        # need to add the planets to this list
	
        my @planets = map { new Astro::Coords(planet => $_) }
          qw/ mars uranus saturn jupiter venus neptune mercury /;
        for (@planets) {
          $_->telescope($tel);
        }

        # Now need to add either the SCUBA secondary calibrators or the
        # heterodyne standards
        $cat->pushstar( map {new Astro::Catalog::Star( coords => $_)} @planets, scuba_2cals() );
	
      } else {
        # continuum pointing catalog if not a Calibrator
        my $pcat = "/local/progs/etc/poi.dat";

        # If that catalogue does not exist fall back to the
        # full catalogue
        $pcat = 'default' unless -e $pcat;

        # This will add the planets automatically
        $cat = new Astro::Catalog( Format => 'JCMT',
                                   File => $pcat );

        # If we can recognise the type of instrument then
        # filter the catalog to only include suitable sources.
        if ($details->{'INSTRUMENT'} eq 'SCUBA2') {
          $cat->filter_by_cb(source_is_type('c'));
        }
        elsif ($details->{'INSTRUMENT'} =~ /^FE_/) {
          $cat->filter_by_cb(source_is_type('l'));
        }
      }

    } elsif ($details->{TELESCOPE} eq 'UKIRT') {
      die "UKIRT not yet supported\n";

    } else {
      die "Should not happen. Telescope was ". $details->{TELESCOPE} ."\n";
    }

    # Make sure we only generate observable sources
    $cat->filter_by_observability;

    # Create object based on AZEL
    # can only do distance if we know where we are now. May require
    # access to the TCS. If we do not have AZ just give everything
    if (exists $details->{AZ}) {
      # The name of the position is either "Ref" or the name supplied
      # in the REFNAME field
      my $refname = ( exists $details->{REFNAME} && defined $details->{REFNAME} ?
                      $details->{REFNAME} ."[Ref]" : "Ref" );

      # Add a reference position if we have one
      my $refcoord = new Astro::Coords(az=> $details->{AZ},
                                       el=> $details->{EL},
                                       units=>'rad',
                                       name => $refname,
                                      );

      $refcoord->telescope( new Astro::Telescope( 'JCMT' ));

      # convert ISO date to Time::Piece object
      my $refdate = OMP::DateTools->parse_date( $details->{TIME} );
      $refcoord->datetime( $refdate );

      # register the reference position
      $cat->reference( $refcoord );

      # sort by distance
      $cat->sort_catalog('distance');

    } else {
      # simply sort by azimuth
      $cat->sort_catalog('az');
    }

    # play sound
    _play_sound('chime.wav');
    # and put up the GUI
    $priv->{FAIL_GUI} = new Tk::AstroCatalog( $w,
                                              -onDestroy => sub { $priv->{FAIL_GUI} = undef;},
                                              -addCmd => sub {
                                                # The actual coordinate (come in as an array)
                                                my $arr = shift;
                                                # Get the most recently selected item
                                                my $c = $arr->[-1];

                                                # if nothing has been selected
                                                # must simply do nothing
                                                return unless $c;

                                                # now reset the gui object
                                                undef $priv->{FAIL_GUI};

                                                print "C is ". $c->status;

                                                my %mods;

                                                # The modentry method can take an Astro::Coords
                                                # object directly if we do not want to specify
                                                # a REFERENCE position.
                                                $mods{TARGET} = $c;

                                                # Add INDEX field
                                                my $index = $details->{INDEX};

                                                # add PROPSRC flag
                                                $mods{PROPAGATE} = 1;

                                                # update the entry parameters in the queue
                                                $Q->modentry( $index, %mods);

                                              },
                                              # On update we trigger a source plot
                                              -upDate => sub {
                                                my $w = shift;
                                                my $cat = $w->Catalog;
                                                return if not defined $cat;
                                                my $curr = $cat->stars;
                                                return if !defined $curr;
                                                my @current = @$curr;

                                                # plot no more than 10 tracks including ref posn
                                                my $max = 9; # this is an index
                                                my $n = ($#current <= $max ? $#current : $max);
                                                return if $n == 0;

                                                # convert "stars" to "coords" (and compensate for ref pos)
                                                @current = map { $_->coords } @current[0..$n-1];

                                                # Must include the reference coordinate if one exists
                                                my $refc = $cat->reference;
                                                unshift(@current, $refc) if defined $refc;

                                                # Want to plot the current time and 1 hour in the future
                                                my $start = gmtime;
                                                my $end = $start + ONE_HOUR;

                                                # plot on xwindow
                                                sourceplot( coords => \@current,
                                                            hdevice => '/xserve', output => '',
                                                            format => 'AZEL',
                                                            start => $start, end => $end,
                                                            objlabel => 'list',
                                                            annotrack => 0,
                                                          );

                                              },
                                              -catalog => $cat,
                                              -transient => 1,
                                              -customColumns => [{
                                                title     => 'Flux',
                                                width     => 5,
                                                generator => sub {
                                                  my $item = shift;
                                                  my $misc = $item->misc();
                                                  return ' --- ' unless $misc
                                                                 and 'HASH' eq ref $misc
                                                                 and defined $misc->{'flux850'};
                                                  return sprintf('%5.1f', $misc->{'flux850'});
                                                }},
                                              ],
                                            );

  } else {
    print "Unable to deal with reason: " . $details->{REASON}. "\n";
    use Devel::Peek;
    my $var = $details->{REASON};
    Dump($var);
  }
}

# Respond to a qompletion request
# Argument is reference to hash of MSBCOMPLETED information
my $QCOMP_GUI;
require Tk::LabEntry;
require Tk::NoteBook;
sub respond_to_qcomplete {
  my $w = shift;
  my $userid = shift;
  my $details = shift;

  # Pull down GUI if it is up
  if ($QCOMP_GUI) {
    $QCOMP_GUI->destroy() if Exists($QCOMP_GUI);
    undef $QCOMP_GUI;
  }

  return unless keys %$details;

  print "Creating MSBCOMPLETE GUI\n";

  # We will need the q control object
  # Get the internal hash data
  my $priv = $w->privateData();
  my $Q = $priv->{QCONTROL};

  # Since we can have multiple MSB triggers at once we need
  # to create our onw top level rather than a dialog box
  my $gui = $w->Toplevel(-title => "MSB Accept/Reject");

  my $userid_gui = (defined $$userid) ? $$userid : '';
  my $entry = $gui->LabEntry( -label => "OMP User ID:",
                              -width => 10,
                              -textvariable => \$userid_gui,
                            )->pack(-fill => 'x', -expand => 1);

  # Tabbed notebook
  my $NB = $gui->NoteBook();
  $NB->pack(-fill => 'x', -expand=>1);

  # A tab per MSB request
  foreach my $tstamp (keys %$details) {

    # Create the tab itself
    my $tab = $NB->add( $tstamp,
                        -label => "MSB".$details->{$tstamp}->{QUEUEID});

    # create the tab contents
    &create_msbcomplete_tab( $tab, $Q, $userid, \$userid_gui, $tstamp,
                             %{$details->{$tstamp}});
  }

  # Now that we have made the popups we can display them
  # Note that this blocks.
  _play_sound('chime.wav');

  # Store the gui reference
  $QCOMP_GUI = $gui;
}

# Create the tab for each MSB in turn
sub create_msbcomplete_tab {
  my $w = shift;
  my $Q = shift;
  my $userid = shift;
  my $userid_gui = shift;
  my $tstamp = shift;
  my %details = @_;

  my $title = $details{MSBTITLE};
  $title = $details{MSBID} if !$title;

  my $text = "MSB '$title' of project $details{PROJECTID} was completed at\n".
    scalar(gmtime($details{TIMESTAMP})) ."UT\n".
      " Please either accept or reject it and enter a reason (if desired)";

  $w->Label( -text => $text,
             -wraplength=>400)->pack(-side =>'top',-expand => 1,-fill=>'both');

  my $Reason = $w->Text(-height => 5, -width => 50)->pack(-side => 'top');

  # Now add on the buttons on the bottom
  my $butframe = $w->Frame->pack;
  $butframe->Button(-text => "Accept",
                    -command => [ \&msbcompletion, $w, $Q,
                                  $userid, $userid_gui, $tstamp, 1, $Reason]
                   )->pack(-side =>'left');
  $butframe->Button(-text => "Reject",
                    -command => [ \&msbcompletion, $w, $Q,
                                  $userid, $userid_gui, $tstamp, 0, $Reason]
                   )->pack(-side =>'left');
  $butframe->Button(-text => "Took no Data",
                    -command => [ \&msbcompletion, $w, $Q,
                                  $userid, $userid_gui, $tstamp, -1, $Reason]
                   )->pack(-side =>'left');
}

# This is the trigger that actually sends the obey in response
# to an accept/reject. Takes a timestamp an accept/reject flag
# and a reference to the text widget containing the reason (if any)
# Is called once for each MSB - this will cause problems since the
# obey will trigger an update of the parameter...
sub msbcompletion {
  my $w = shift;
  my $Q = shift;
  my $userid = shift;
  my $userid_gui = shift;
  my $tstamp = shift;
  my $accept = shift;
  my $rw = shift;

  # Did the user alter the OMP user ID via the GUI?
  if ($$userid_gui ne $$userid) {
    # Clear the stored user ID so that if validation fails, we will
    # open the normal prompt at the next step.
    $$userid = undef;

    # Did we get a non-empty user ID?
    if ($$userid_gui =~ /\w/) {
      eval {
        # Do what OMP::General::determine_user would do to validate the
        # newly supplied OMP user ID.
        my $omp_user_obj = OMP::UserServer->getUser($$userid_gui);
        $$userid = $omp_user_obj->userid() if defined $omp_user_obj;
      };
    }
  }

  # Attempt to get a user id but non fatal if we do not get it.
  # Use an eval block to trap database errors.
  if (!defined $$userid || $$userid !~ /\w/) {
    eval {
      my $OMP_User_Obj = OMP::General->determine_user( $w );
      $$userid = $OMP_User_Obj->userid if defined $OMP_User_Obj;
    };
  }

  # read the widget
  my $reason = $rw->get( '0.0','end');

  # Should verify user here if we have one

  print "*****************************\n";
  print "** TSTAMP  $tstamp\n";
  print "** USER    $$userid\n";
  print "** ACCEPT  $accept\n";
  print "*****************************\n";

  # Send completion message
  $Q->msbcomplete( $$userid, $tstamp, $accept, $reason);

  # need to undefine the gui variable
  # Note that this is strange when we have multiple MSBs
  destroy $QCOMP_GUI if defined $QCOMP_GUI && Exists($QCOMP_GUI);
  undef $QCOMP_GUI;

}

# hack
# Return all the SCUBA secondary calibrators
# This really needs to be obtained from a separate class that knows
# about scuba calibration since many systems would like to know
# this information
# Returns Astro::Coords objects as a list:
# Should probably include the planets here!
#    @calcoords = scuba_cals();
sub scuba_2cals {
  my @coords = (
                {
                 name => 'OH231.8',
                 ra => '07 42 16.939',
                 dec => '-14 42 49.05',
                 type => 'J2000',
                },
                {
                 name => 'IRC+10216',
                 ra => '09 47 57.382',
                 dec => '13 16 43.66',
                 type => 'J2000',
                },
                {
                 name => '16293-2422',
                 type => 'J2000',
                 ra => '16 32 22.909',
                 dec => '-24 28 35.60',
                },
                {
                 name => 'HLTau',
                 ra => '04 31 38.4',
                 dec => '18 13 59.0',
                 type => 'J2000',
                },
                {
                 name => 'CRL618',
                 ra => '04 42 53.597',
                 dec => '36 06 53.65',
                 type => 'J2000',
                },
                {
                 name => 'CRL2688',
                 ra => '21 02 18.805',
                 dec => '36 41 37.70',
                 type => 'J2000',
                },
                {
                 name => 'V883Ori',
                 ra => '05 38 19',
                 dec => '-07 02 02.0',
                 type => 'J2000',
                },
                {
                 name => 'AlphaOri',
                 ra => '05 55 10.31',
                 dec => '07 24 25.4',
                 type => 'J2000',
                },
                {
                 name => 'TWHya',
                 ra => '11 01 51.91',
                 dec => '-34 42 17.0',
                 type => 'J2000',
                },
                {
                 name => 'Arp220',
                 ra => '15 34 57.21',
                 dec => '23 30 09.5',
                 type => 'J2000',
                },

               );

  my $tel = new Astro::Telescope( 'JCMT' );
  my @c = map { new Astro::Coords( %$_ ) } @coords;
  foreach (@c) {
    $_->telescope($tel);
  }
  return @c;
}

=item source_is_type($type_code)

Return a "callback" subroutine reference suitable for use with
C<Astro::Catalog::filter_by_cb> which can be used to select only
sources with the given type code.  The type code is a single
character enclosed in square brackets at the start of
the comment string.

For example, in the JCMT pointing catalog, a continuum source
might have a comment like:

    [c] [S1] 0.6 - 0.8 Jy (2004 Dec)

And a line source might have a comment like:

    [l] L1+ 2-1 31.7 2-1 IRAM 66.2

These could be selected using C<source_is_type('c')> and
C<source_is_type('l')> respectively.

Currently returns true if the comment doesn't seem to include
a type code.  This ensures that planets will appear in the
pointing catalog for both types of instrument.

=cut

sub source_is_type {
    my $type = shift;

    return sub {
        my $comment = shift->coords()->comment();

        unless ($comment =~ /^\[(\w)\]/) {
            return 1;
        }

        my $code = $1;

        return $code eq $type;
    };
}

=back

=head1 ADVERTISED WIDGETS

The following sub-widgets can be obtained by name:

=over 4

=item B<messages>

Text widget associated with informational messages.

=item B<errors>

Text widget associated with error messages.

=back

=head1 INTERNALLY ADVERTISED WIDGETS

The following widgets are advertised but are not part of the public interface:

=over 4

=item _qstatus

The label widget associated with the current status of the queue.

=item _qcontents

The list box associated with the actual queue contents.

=back

=head1 AUTHOR

Tim Jenness E<lt>t.jenness@jach.hawaii.eduE<gt>.

Copyright (C) 2002-2004 Particle Physics and Astronomy Research Council.
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
