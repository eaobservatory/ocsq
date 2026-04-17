#!perl

use Test::More tests => 1 + 4;

require_ok('Queue::Entry');

my $entry = Queue::Entry->new('label1', 'ENTITY');

isa_ok($entry, 'Queue::Entry');

is($entry->getTargetComment, undef);

$entry->setTarget('TARGET', 'COMMENT');

is($entry->getTargetComment, 'COMMENT');

$entry->clearTarget;

is($entry->getTargetComment, undef);
