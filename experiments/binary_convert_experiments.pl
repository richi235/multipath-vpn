#!/usr/bin/env perl

use strict;
use warnings;
use v5.12;


use Convert::Binary::C;

my $c = Convert::Binary::C->new();
# Ist mega das geficke mit uint64_t, bzw überhaupt mit den C integer typen zum laufen zu bringen
# deswgen: kein Convert::Binary::C ....


my $c_types = q{
struct tfrc_tx_info {
    uint64_t tfrctx_x;
    uint64_t tfrctx_x_recv;
    uint32_t tfrctx_x_calc;
    uint32_t tfrctx_rtt;
    uint32_t tfrctx_p;
    uint32_t tfrctx_rto;
    uint32_t tfrctx_ipi;
}; } ;

$c->Include('/usr/include');
$c->parse_file('stdint.h');
$c->parse($c_types);


#my $empty_dccp_info_struct = $c_types->pack('tfrc_tx_info');
say($c_types);

