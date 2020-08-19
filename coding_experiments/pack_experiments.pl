#!/usr/bin/env perl

use strict;
use warnings;
use v5.12;
use Data::Hexdumper;

use Data::Dumper;


my $empty_dccp_info = pack('QQLLLLL');
my $empty_dccp_info2 = pack('QQLLLLL', "0");

say hexdump $empty_dccp_info ;
say bytes::length $empty_dccp_info ;

say hexdump $empty_dccp_info2 ;
say bytes::length $empty_dccp_info2 ;
