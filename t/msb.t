#!perl

# Test Queue::Contents with MSB observed triggers

use Test::More tests => 40;

require_ok( 'Queue::Contents::Indexed' );
require_ok( 'Queue::MSB' );
require_ok( 'Queue::Entry' );

# Create some dummy entries
my @msb1 = (
	    new Queue::Entry( "msb1entry1" ),
	    new Queue::Entry( "msb1entry2" ),
	    new Queue::Entry( "msb1entry3" ),
	    new Queue::Entry( "msb1entry4" ),
	    new Queue::Entry( "msb1entry5" ),
	    new Queue::Entry( "msb1entry6" ),
	   );

my @msb2 = (
	    new Queue::Entry( "msb2entry1" ),
	    new Queue::Entry( "msb2entry2" ),
	    new Queue::Entry( "msb2entry3" ),
	    new Queue::Entry( "msb2entry4" ),
	    new Queue::Entry( "msb2entry5" ),
	    new Queue::Entry( "msb2entry6" ),
	   );

# Create two MSB objects and associate them with @msb1 and @msb2
my $msb1 = new Queue::MSB( entries => \@msb1 );
isa_ok( $msb1, "Queue::MSB" );

my $msb2 = new Queue::MSB( entries => \@msb2 );
isa_ok( $msb2, "Queue::MSB" );

# Now make sure that we have MSB association
for (@msb1) {
  is( $_->msb, $msb1,"Make sure MSB object is attached to MSB1");
}
for (@msb2) {
  is( $_->msb, $msb2, "Make sure MSB object is attached to MSB2");
}

# hasBeenObserved
ok( ! $msb1->hasBeenObserved, "Has not been observed" );
$msb1->hasBeenObserved(1);
ok( $msb1->hasBeenObserved, "Has been observed" );

# Check that we have first and last obs correctly
ok( $msb1[0]->firstObs, "Is first observation in MSB1");
ok( $msb2[0]->firstObs, "Is first observation in MSB2");
ok( $msb1[-1]->lastObs, "Is last observation in MSB1");
ok( $msb2[-1]->lastObs, "Is last observation in MSB2");

ok( !$msb1[-1]->firstObs, "Is not first observation in MSB1");
ok( !$msb2[-1]->firstObs, "Is not first observation in MSB2");
ok( !$msb1[0]->lastObs, "Is not last observation in MSB1");
ok( !$msb2[0]->lastObs, "Is not last observation in MSB2");

# Create a queue
my $q = new Queue::Contents::Indexed();
isa_ok( $q, "Queue::Contents" );

# Add to the queue
$q->loadq( @msb1 );
$q->addback( @msb2 );

is($q->countq, scalar(@msb1)+scalar(@msb2),"Check count in queue");


# Specify a callback for completion
my $triggered;
my $cb = sub { $triggered = 1;};
$msb1->msbcomplete( $cb );
$msb2->msbcomplete( $cb );

# MSB1 has been "observed". If we remove it we should get the
# callback triggered
$q->cutmsb( 0 );
ok( $triggered, "Trigger completion callback via cutmsb" );

# MSB2 has not been "observed". If we remove it we should get
# no trigger [difficult to confirm the correct logic]
$triggered = 0; # reset
$q->cutmsb( 0 );
ok( ! $triggered, "Trigger completion callback for msb2" );


# Need to redo the MSB association since cutmsb clears it
$msb1 = new Queue::MSB( entries => \@msb1 );
isa_ok( $msb1, "Queue::MSB" );

# Add the msb1 back on the queue
$q->clearq;
$q->addback( @msb1 );

# insert a calibration
my $cal = new Queue::Entry( "cal" );
$q->insertq( 2, $cal );

is( $q->countq, scalar(@msb1) + 1, "Count MSB1 + cal obs" );

# If we cut the msb we should remove everything including the cal
$q->cutmsb( 0 );
is($q->countq, 0, "Queue should be empty");


# Need to redo the MSB association since cutmsb clears it
$msb1 = new Queue::MSB( entries => \@msb1 );
isa_ok( $msb1, "Queue::MSB" );

# Add the msb1 back on the queue
$q->clearq;
$q->addback( @msb1 );

# Remove the first entry
my ($rem) = $q->cutq(0,1);
isa_ok($rem,"Queue::Entry");

# check status
ok($q->getentry(0)->firstObs,"New first obs");


# Now do a replace
my $rep = new Queue::Entry("replacement");
$q->replaceq(3, $rep);

# and make sure this is an MSB
ok($rep->msb, "Replacement is associated with an MSB");

# Set the curentry to the last but one entry
$q->curindex( $q->maxindex - 1);

# Mark it as observed
$msb1->hasBeenObserved( 1 );

# Associate complete trigger
$triggered = 0;
$msb1->msbcomplete( $cb );

# Associate with reference entry
$msb1->refentry( $q->curentry );

# And cut the last two entries
$q->cutq( $q->maxindex - 1, 2);

is($triggered, 1, "Remove last two entries from queue");


# Test clearq functionality
$q->clearq;
$q->addback( @msb1 );
$msb1 = new Queue::MSB( entries => \@msb1 );
$msb1->hasBeenObserved(1);
$triggered = 0;
$msb1->msbcomplete( $cb );
$q->clearq;
is($triggered, 1, "Clear queue with an MSB observed");
