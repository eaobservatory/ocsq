#!perl

# Test of the filtering function in Tk::OCSQMonitor.

use strict;

use JAC::Setup qw/drama omp/;

use Test::More tests => 5;
use Astro::Catalog;

require_ok('Tk::OCSQMonitor');

my $cat = new Astro::Catalog(
    Format => 'JCMT',
    Data => \*DATA,
    ReadOpt => {incplanets => 0}
);

cat_names($cat, [qw/PVCep UUPeg CRL2688 oCeti XPav/]);

$cat->filter_by_cb(Tk::OCSQMonitor::source_is_type('c'));

cat_names($cat, [qw/PVCep CRL2688 oCeti XPav/]);

$cat->reset_list();

$cat->filter_by_cb(Tk::OCSQMonitor::source_is_type('l'));

cat_names($cat, [qw/CRL2688 oCeti/]);

$cat->reset_list();

$cat->filter_by_cb(Tk::OCSQMonitor::source_is_type('w'));

cat_names($cat, [qw/UUPeg oCeti XPav/]);

sub cat_names {
    my $cat = shift;
    my $names = shift;
    is((join ',', map {$_->id} $cat->stars), (join ',', @$names));
}

__DATA__
PVCep           20 45 53.943 + 67 57 38.66 RJ    n/a     1.35    n/a  LSR  RADIO [c]    [S2] 1.0 Jy Sandell 2011
UUPeg           21 31 04.160 + 11 09 13.30 RJ    n/a     n/a     n/a  LSR  RADIO [w]
CRL2688         21 02 18.750 + 36 41 37.80 RJ  -   35.4  5.9    80.0  LSR  RADIO [cl] c Secondary flux calibrator
oCeti           02 19 20.803 - 02 58 43.54 RJ  +   46.5 43.1    19.0  LSR  RADIO [clw] pm
XPav            20 11 46.030 - 59 56 12.70 RJ  -   21.0  1.2     n/a  LSR  RADIO [cw]
