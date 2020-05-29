#!/usr/bin/env perl
# This is mostly for trying out the Log::Fast module
# to see if (and how) it does what I want/need

use warnings;
use strict;
use v5.10;

use Getopt::Long;
use Log::Fast;

# One out of:
# ERR
# WARN
# NOTICE
# INFO
# DEBUG
my $loglevel_txrx = 'NOTICE';
my $loglevel_algo = 'NOTICE';

GetOptions('ltx=s'         => \$loglevel_txrx,
            'lalgo=s'       => \$loglevel_algo);

#say($loglevel_txrx);

# * Eigene file aufmachen oder stdout?
#   - Eigene file wär egientlich schon mal cool
# * Eigene file pro event art?
#   - puh
my $TXRXLOG = Log::Fast->new({
    level           => $loglevel_txrx,
    type            => 'fh',
    fh              => \*STDOUT,
});

my $ALGOLOG = Log::Fast->new({
    level           => $loglevel_algo,
    type            => 'fh',
    fh              => \*STDOUT,
});

$TXRXLOG->NOTICE("sending through socket.....");
$TXRXLOG->WARN("Called with no subtun available");

$ALGOLOG->NOTICE("Following stats: ");
$ALGOLOG->WARN("Only 1 subtunnel");
