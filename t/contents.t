#!perl

# Test Queue::Contents

use Test::More tests => 108;

require_ok( 'Queue::Contents::Indexed' );
require_ok( 'Queue::Contents::PasteBuff' );
require_ok( 'Queue::Entry' );

# Create some dummy entries
my @entries = (
	       new Queue::Entry( "entry1" ),
	       new Queue::Entry( "entry2" ),
	       new Queue::Entry( "entry3" ),
	       new Queue::Entry( "entry4" ),
	       new Queue::Entry( "entry5" ),
	       new Queue::Entry( "entry6" ),
	      );

is(scalar(@entries), 6, "Check count of test array");

# Create a Queue::Contents object
# And test initial state
my $q = new Queue::Contents::Indexed();
ok( $q, "Empty queue Object is defined" );
is( $q->countq, 0, "Queue is empty");
is( $q->curindex, undef, "Index is undefined");

# And store the entries
$q = new Queue::Contents::Indexed( @entries );
ok( $q, "Populated queue defined" );
is($q->countq, scalar(@entries),"Check count");
is($q->curindex, 0,"Default index position");

# Increment the index
print "# Index manipulations\n";
ok($q->incindex,"Inc index");
is($q->curindex, 1,"Check index");
ok($q->decindex, "Dec index");
is($q->curindex, 0, "Check index");
ok(! $q->decindex, "Can not dec index");

# increment the index until we hit the end
for my $i (0..$#entries-1) {
  ok($q->incindex, "Inc index");
}
ok(!$q->incindex, "Can not inc index");

# Now try incrementing by more than 1
is($q->curindex(2),2, "set index to 2");
ok($q->incindex(2),"inc by 2");
ok($q->curindex(4),"check index");
ok($q->incindex(10),"inc by 10");
ok($q->curindex($q->maxindex),"check is maxindex");
ok(!$q->incindex(10),"inc by 10");

# Decrementing
is($q->curindex, $q->maxindex,"check is maxindex");
ok($q->decindex(2),"dec by 2");
is($q->curindex(),3,"check index");
ok($q->decindex(5),"dec by 5");
is($q->curindex(),0,"check is 0");
ok(!$q->decindex(),"dec index");

# Try to change the index
is( $q->curindex(2), 2, "set index to 2");
is( $q->curindex($q->countq), 2,"set to count"); # this will fail
is( $q->curindex(-1), 2,"set to -1");         # as will this
is( $q->curindex(3), 3,"set to 3");

# Get the next and previous index
is( $q->nextindex, 4, "get next index");
is( $q->previndex, 2, "prev index");

$q->curindex(0);
is( $q->previndex, undef,"prev index undef");
is( $q->nextindex, 1, "next index");
$q->curindex($q->countq - 1);
is( $q->nextindex, undef,"next index undef");
is( $q->previndex, $q->countq - 2, "cmp prev with count");

# Retrieve entries
$q->curindex(3);
is( $q->curentry, $entries[3], "get curentry");
is( $q->nextentry, $entries[4],"get nextentry");
is( $q->preventry, $entries[2],"get preventry");

# Comparisons
print "# CMP\n";
is( $q->cmpindex(3), 0 , "cmp match");
is( $q->cmpindex(2), -1, "cmp low");
is( $q->cmpindex(5), 1,  "cmp high");


# CUTQ
print "# CUTQ\n";
is($q->curindex(1),1, "set index 1");
is(scalar($q->cutq(2,2)),2, "cutq 2");
is($q->curindex,1,"index 1");
is($q->countq, 4,"count is 4");
$q->curindex(3);
is(scalar($q->cutq(2)),1,"cut 1");
is($q->curindex,2, "index is 2");
is($q->countq(),3,"count is 3");

# ADDBACK
print "# ADDBACK\n";
$q->curindex(2);
$q->addback(new Queue::Entry("entry7"));
is($q->curindex(),2,"index is 2"); # should not affect index
is($q->countq(),4,"count is 4");

# ADDFRONT
print "# ADDFRONT\n";
$q->addfront(new Queue::Entry("entry8"),new Queue::Entry("entry9"));
# automatically increment
is($q->curindex,4,"index is 4");
is($q->countq,6, "count is 6");

# SHIFTQ
print "# SHIFTQ\n";
is($q->curindex(4),4,"check index");
ok($q->shiftq, "shift");
is($q->curindex, 3,"check index");
is($q->countq,5,"check count");

# POPQ
print "# POPQ\n";
ok($q->popq,"pop");
is($q->curindex,3,"check index");
is($q->countq,4,"check count");
ok($q->popq,"pop");
is($q->curindex,2,"check index");
is($q->countq,3,"check count");

# INSERTQ
print "# INSERTQ\n";
$q->insertq(2,new Queue::Entry("entry10"),
	    new Queue::Entry("entry11"));
is($q->curindex(),4,"check index");
is($q->countq, 5,"check count");
$q->insertq(2,new Queue::Entry("entry12"),
	    new Queue::Entry("entry13"));
is($q->curindex(),6,"check index");
is($q->countq, 7,"check count");
$q->curindex(3);
$q->insertq(4,new Queue::Entry("entry12"),
	    new Queue::Entry("entry13"));
is($q->curindex(),3,"check index");
is($q->countq, 9,"check count");

$q->insertq(36,new Queue::Entry("entry12"),
	    new Queue::Entry("entry13"));
is($q->curindex(),3,"check index");
is($q->countq, 11,"check count");

$q->insertq(-22,new Queue::Entry("entry12"),
	    new Queue::Entry("entry13"));
is($q->curindex(),5,"check index");
is($q->countq, 13,"check count");

# REPLACEQ
ok($q->replaceq(2, new Queue::Entry("entry14"),"replace entry"));
is($q->curindex(),5,"check index");
ok(! $q->replaceq(4,undef,"fail replace"));

# CLEARQ
print "# CLEARQ\n";
$q->clearq;
is($q->countq,0,"check count");
is($q->curindex, undef,"check index");

# Now check to make sure we dont trigger warnings with
# an empty queue.
print "# Empty Queue\n";
is($q->popq,undef,"check pop");
is($q->shiftq,undef,"shift");
is($q->cutq(1), 0,"cut"); # scalar context
is($q->getentry(3),undef,"getentry");
is($q->nextentry(),undef,"nextentry");
is($q->preventry(),undef,"preventry");
is($q->curentry(),undef,"curentry");
is($q->cmpindex(3),undef,"cmp");
is($q->cmpindex, undef,"cmp");
is($q->previndex, undef,"previndex");
is($q->nextindex, undef,"previndex");
ok(!$q->decindex,"decindex");
ok(!$q->incindex,"incindex");

$q->insertq(4, new Queue::Entry("entry14"),
	   new Queue::Entry("entry15"));
is($q->curindex,0,"check index");
is($q->countq, 2,"check count");

$q->clearq;
$q->insertq(-1, new Queue::Entry("entry16"));
is($q->curindex,0,"check index");
is($q->countq,1,"check count");


# Now with a paste buffer

# Create a Queue::Contents object
# And store the entries
print "# Paste buffer\n";
$q = new Queue::Contents::PasteBuff( @entries );
ok( $q, "paste queue" );
is($q->countq, scalar(@entries),"check count");

$q->cutq(3,2);
is($q->countq, 4, "check count");
is($q->pastebuffer->countq, 2, "check paste count");
$q->pasteq(1);

is($q->countq, 6, "check count");
is($q->pastebuffer->countq, 0, "check paste count");
