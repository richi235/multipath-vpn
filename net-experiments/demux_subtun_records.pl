#!/usr/bin/env perl
# demux_subtun_records.pl --- This takes a .tsv file as input that contains logs
# for 3 subtuns, creates 3 tsv files, and demuxes the lines accordingly to the subtun id (second column)
# Author: Richard <richi@yang.nibelungen>

use warnings;
use strict;
use v5.10;


open(my $subtun0_fd ,">", "subtun0_time_inflight_cwnd_srtt.tsv")
    or die("can not open subtun0 file");
open(my $subtun1_fd ,">", "subtun1_time_inflight_cwnd_srtt.tsv")
    or die("can not open subtun1 file");
open(my $subtun2_fd ,">", "subtun2_time_inflight_cwnd_srtt.tsv")
    or die("can not open subtun2 file");

# this maps subtun ids to file descriptors, to ake the following
# loop more elegant and easy (smart data structures, simple code)
my %subtun_id_to_fd = (
    0 => $subtun0_fd,
    1 => $subtun1_fd,
    2 => $subtun2_fd
);

# The main loop, this processes all the input lines
while (<>) {
    my @fields = split(/\s+/);
    my $subtun_id = $fields[1];
    if ( @fields != 5) {
        say("Invalid line too much or too little fields: \n$_");
        next;
    }

    if (0 <= $subtun_id && $subtun_id <= 2) {
        print { $subtun_id_to_fd{$subtun_id} } $_ ;
    } else {
        # say("Error scanned invalid line");
    }
}
