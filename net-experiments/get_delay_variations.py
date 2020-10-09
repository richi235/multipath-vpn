#!/usr/bin/env python3
import sys
from scapy.all import *

pcap_filename = sys.argv[1]
packets = rdpcap(pcap_filename)

# for pkt in packets:
# 	delta = pkt.time - prev_time
# 	print '{}    {}'.format(packet_number,  delta)
# 	prev_time = pkt.time
# 	packet_number += 1


# sequence number to arrival time mapping array
seq_to_arrival_time = [None]*int(len(packets)*1.5)
# This initializes the array with None values, necesarry for the way we populate it later
# we make it 1.5 times the number of packets in case we lost a lot of packets an the
# sequencenumbers respect that (like 1000 packets received but the highest got seq number 1500 so 500 got lost)

print("seq_array_len: ", len(seq_to_arrival_time))

for pkt in packets:
	seq_field_bytestring = pkt.load[0:4]
	seq_number = int.from_bytes( seq_field_bytestring, byteorder='big', signed=True)
	print("seq# ", seq_number)
	if seq_number < 0:
		continue
	seq_to_arrival_time[seq_number] = pkt.time

prev_time = seq_to_arrival_time[0]

for seq, arrival_time in enumerate(seq_to_arrival_time):
	if arrival_time == None:
		continue

	delta = arrival_time - prev_time
	print('{}    {}'.format(seq,  delta))
	prev_time = arrival_time




# Array format:
#
#  Time           |
# ----------------------------
#  Sequenz number |
#   (Index)
