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
                           -user => new OMP::User(),
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

=cut

use strict;
use warnings;
use Carp;
use Tk;
use File::Spec;

# We use DRAMA but we assume the queue gui is initialising DRAMA
use DRAMA;
use Queue::Control::DRAMA;
use FindBin;

$DRAMA::MAXREPLIES = 40;

our $AUDIO_DIR = File::Spec->catdir($FindBin::RealBin,"audio");

use vars qw/ $VERSION /;

use base qw/ Tk::Derived Tk::Frame /;
Construct Tk::Widget 'OCSQMonitor';


sub Populate {
  # Read the base widget and the supplied arguments
  my ($w, $args) = @_;

  # Provide defaults for width and height
  my %def = ( -qwidth => 110, -qheight => 10, -msgwidth => 100 );

  # merge with supplied arguments
  %$args = ( %def, %$args );

  croak "Must supply a queue name [qtask]"
    unless exists $args->{'-qtask'};

  # Configure options
  $w->ConfigSpecs( -qtask => ['PASSIVE'],
		   -qwidth => ['PASSIVE'],
		   -qheight => ['PASSIVE'],
		   -msgwidth => ['PASSIVE'],
		   -user => ['PASSIVE'],
		 );

  # Generic widget options
  $w->SUPER::Populate($args);

  # Copy args to configure options
  $w->configure('-qtask' => $args->{'-qtask'});
  $w->configure('-qwidth' => $args->{'-qwidth'});
  $w->configure('-qheight' => $args->{'-qheight'});
  $w->configure('-msgwidth' => $args->{'-msgwidth'});
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
  #$Fr3->Button( -text => 'ADD', -command => \&launchFS)->pack(-side => 'left');

  $Fr3->Button( -text => 'CLEAR',  -command => sub { $priv->{QCONTROL}->clearq }
	      )->pack(-side => 'left');
#  $Fr3->Button( -text => 'DISPOSE MSB',  -command => \&disposemsb)->pack(-side => 'left');
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
  $Fr2->Label(-text => 'Queue contents')->grid(-row=>0,-column=>1);


  my $ContentsBox = $Fr2->Scrolled('Text',
				   -scrollbars => 'e',
				   -wrap => 'none',
				   -height => $args->{'-qheight'},
				   -width  => $args->{'-qwidth'},
				   #		 -state  => 'disabled',
				  )->grid(-row=>1,-column=>1);

  $ContentsBox->bindtags(qw/widget_demo/);        # remove all bindings but dummy "widget_

  # We must be allowed to access the Q status widget
  $w->Advertise( '_qcontents' => $ContentsBox);

  # Setup a Text widget that will take all the output sent to MsgOut
  $priv->{MORE_INFO} = 0;  # is the window visible
  $priv->{MORE_DISPLAYED_ONCE} = 0; # Has it been visible at least once?

  my $MsgText = $Fr4->Scrolled('Text',-scrollbars=>'w',
			       -height=>16,
			       -width=>$args->{'-msgwidth'},
			      );

  my $MsgBut = $Fr4->Checkbutton(-variable => \$priv->{MORE_INFO},
				 -text     => 'Info messages...',
				 -command => [ 'show_info', $w ],
				)->grid(-row=>0,-column=>1,-sticky=>'w');

  my $ErsText = $Fr4->Scrolled('Text',-scrollbars=>'w',
			       -height=>4,
			       -width=>$args->{'-msgwidth'},
			      );

  $priv->{MORE_ERS} = 0;
  my $ErsBut = $Fr4->Checkbutton(-variable => \$priv->{MORE_ERS},
				 -text     => 'Error messages...',
				 -command => ['show_ers', $w],
				)->grid(-row=>2,-column=>1,-sticky=>'w');


  # Advertise the messages and error text widgets
  $w->Advertise( 'messages' => $MsgText);
  $w->Advertise( 'errors' => $ErsText );


  # Force visibility
  $priv->{MORE_INFO} = 1;
  $w->show_info();

  $priv->{MORE_ERS} = 1; # Force display
  $w->show_ers();

  # print information to this text widget
  my $status = new DRAMA::Status;
  Dits::UfacePutMsgOut( sub {
			  $w->write_text_messages( 'messages', $_[0] );
			},
			$status);

  # Also want this to appear in the log file so just print it
  Dits::UfacePutErsOut( sub {
			  print "Err: $_[1]\n";
			  $w->write_text_messages( 'errors', $_[1] );
			},
			$status);


  # These variables record whether or not we have an active monitor
  # configured. 0 = we are running, 1 = it has been cancelled somehow
  $priv->{QUEUE_CANCELLED} = 1;

  # Kick them off for 30 second repeat
  $w->check_monitors(30);

  # Finally, pack frames into top frame
  $Fr1->grid(-row => 0, -column =>0, -sticky=>'w');
  $Fr2->grid(-row => 1, -column =>0);
  $Fr3->grid(-row => 2, -column =>0);
  $Fr4->grid(-row => 3, -column =>0, -sticky=>'w');

  return;
}

# Callback triggered when the widget is destroyed
sub _shutdown {
  my $w = shift;
  my $priv = $w->privateData;

  print "***********************************\n";

  use Data::Dumper;
  print Dumper($priv);

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
	  "TIMEONQUEUE", "JIT_MSG_OUT", "JIT_ERS_OUT",
	  { -monitorvar => $priv->{MONITOR},
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
  my $mega = shift;  # The mega widget
  my $priv = $mega->privateData;
  my $w = $mega->Subwidget('messages');
  if ($priv->{MORE_INFO}) {
    $w->grid(-row=>1,-column=>1,-sticky=>'ens');
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
    $w->grid(-row=>3,-column=>1,-sticky=>'ens');
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
    print "+++++++++++++++++ $param -------- $value \n";
    $w->write_text_messages( 'messages', $value);

  }
  return $value if not ref($value);
    $value->List(new DRAMA::Status);

  # Assume we have a Sds
  my %tie;
  tie %tie, "Sds::Tie", $value;
    $value->List(new DRAMA::Status);
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
    # When FAILURE triggers we should obtain the ODF, see what the problem
    # is, pop up a gui to request help.
    # Problem is that you can not do this until the monitor has completed.
    # If you try to do an obey to retrieve the ODF (if we decide not to publish
    # it as part of the FAILURE Sds parameter) you cannot use an "obeyw"
    # you can also not do any Tk event handling. The problem is the monitor
    # must complete before you go into any other event handling. This implies
    # that we have to set a variable from to indicate that FAILURE has returned
    # and then work that out when we enter the event loop. Easiest thing
    # is to do an after() for a few milliseconds later.

    use Data::Dumper;
    print Dumper(\%tie);

    # if we are prompting for changes to the ODF we
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
      respond_to_failure($tie{DETAILS});

    }

  } elsif ($param eq 'MSBCOMPLETED') {

    print "Got MSBCOMPLETED parameter:\n";
    use Data::Dumper;
    print Dumper(\%tie);

    # Always delete the window if it is up since the details might
    # be different
    if ($priv->{QCOMP_GUI}) {
      $priv->{QCOMP_GUI}->destroy if Exists($priv->{QCOMP_GUI});
      undef $priv->{QCOMP_GUI};
    }

    # first check that we have to react
    if (keys %tie) {
      # Put up the window requsting clarification on accept/reject
      # We can do this without an after() because this method
      # just puts up a GUI rather than blocking and waiting
      # for a response directly.
      print "Creating MSBCOMPLETE GUI\n";
      respond_to_qcomplete(\%tie);
    }
  } elsif ($param eq 'JIT_ERS_OUT') {
    $value->List(new DRAMA::Status);
    $w->write_text_messages( 'errors', $tie{MESSAGE});

    print "+++++++++++++ JIT_ERS_OUT -----------\n";
    $value->List(new DRAMA::Status);
    use Data::Dumper;
    print Dumper(\%tie);

    print "++++++++++++++++++++------------------\n";

      # look for errors from the queue/scucd that are not coming
      # to us directly because we did not initiate the action
#      for (@{$tie{MESSAGE}}) {
#	if ($_ =~ /^ERROR/) {
#	  print "Triggering ERROR associated with message from the queue\n";
#	  _play_sound('alert.wav');
#	  last;
#	}
#      }


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

  if ($priv->{MONITOR}->{STATUS} =~ /^Stop/i) {
#    print "Starting Q\n";
    $priv->{QCONTROL}->startq;
  } else {
#    print "Stopping Q\n";
    $priv->{QCONTROL}->stopq;
  }

}

# Subroutine to play a sound on the speaker. Do not test
# return value since it should be non-fatal if it fails
sub _play_sound {
  my $file = shift;
  print "PLAYING A SOUND\n";
  return;
  $file = File::Spec->catfile($AUDIO_DIR, $file);
  system("/usr/bin/esdplay",$file);
  return;
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
		      [ \&ContentsMenu, $index, Ev('X'), Ev('Y')] ,
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

      # and make it visible (index needs to be incremented by 1
      # here to make sure the line is visible rather than just its
      # top
      $index++;
      $ContentsBox->see("$index.0");
    }
  }
}

# GUI dealing with responding to a failure of an ODF to load
# because it is missing information
# Arguments are: The ODF, the failure details

sub respond_to_failure {
  my $w = shift;
  my $details = shift;

  print Dumper($details);
  print "Unable to deal with reason: " . $details->{REASON}. "\n";
  use Devel::Peek;
  my $var = $details->{REASON};
  Dump($var);
}



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
