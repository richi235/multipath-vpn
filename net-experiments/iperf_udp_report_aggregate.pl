#!/usr/bin/env perl
# This script gets as input text a few specific lines of iperf output
# (The totals for every UDP flow, generated at the end of the measurement)
# We aggregate all these per flow values and print averages to stdout
# (for one-way-delay (OWD), reordered packet count, jitter and throughput)

use strict;
use warnings;
use v5.10;

my $number_of_flows  = 0;

# Output parameters
my $throughput_sum   = 0;
my $owds_sum         = 0;
my $jitter_sum       = 0;
my $reordered_packets_sum = 0;


### Example input text: 
# [  6] 0.0000-29.9897 sec  3.73 MBytes  1.04 Mbits/sec   0.087 ms   14/ 2675 (0.52%) 29.176/27.399/105.972/ 1.123 ms   89 pps  4.47
# [  6] 0.0000-29.9897 sec  1 datagrams received out-of-order
# [  4] 0.0000-29.9896 sec  3.73 MBytes  1.04 Mbits/sec   0.677 ms   15/ 2675 (0.56%) 28.886/27.402/158.704/ 0.725 ms   89 pps  4.51
# [  4] 0.0000-29.9896 sec  2 datagrams received out-of-order


# With markers:
# [  3] 0.0000-29.9914 sec  3.73 MBytes  1.04 Mbits/sec   0.036 ms   17/ 2675 (0.64%) 30.932/30.606/110.041/ 0.809 ms   89 pps  4.21
# 0  1     2            3     4   5       6    7            8   9    10   11    12       13                   14   15   16 17    18  

# Notes:
# For every flow we have two lines:
# 1. A reordered packets line
# 2. A "stats" line
#
# So we have to process them seperately, and use one of them to increment the flow count variable

# 1.  Read in stuff and populate variables
while(<>)
{

	#grep -v "^\[SUM\]"  | 
	#grep -e " 0\.0000-[1-9][0-9]" | 
	#grep -e "ms .* ms" -e "out-of-order"
	
	## Ignore all the irrelevant lines:
	if( /^\[SUM\]/ ) { next; };
	if( ! / 0\.0000-[1-9][0-9]/ ) { next; };
	if(! (/ms .* ms/ || /out-of-order/ ) ) { next; };


	# Not sure if this lines appears if there are 0 reordered packets
	# So we do not increment flow count here
	if (m/received out-of-order/) {  # reordered line (1.)
		my @fields = split();
		my $reordered_count = $fields[4];
		$reordered_packets_sum += $reordered_count;
	} elsif (m:[\d.]+/[\d.]+/[\d.]+/ :) {  # stats line (2.)
		$number_of_flows++;

		my @fields = split();
		
		my $delay_string = $fields[13];
		my $jitter = $fields[8];
		my $throughput = $fields[6];

		my @delays = split('/', $delay_string);
		my $avg_owd = $delays[0];
		# say("$throughput    $jitter   $avg_owd");
		
		$owds_sum       += $avg_owd;
		$jitter_sum     += $jitter;
		$throughput_sum += $throughput;

	} else {
		say("Error unparsable line: " . $_);
	}
}	

# 2.  Print results

say("# Throughput_sum   jitter_avg              OWD_avg            reorered_packets_sum");
say("$throughput_sum               " . $jitter_sum/$number_of_flows . "      " . $owds_sum/$number_of_flows . "      $reordered_packets_sum");

