#!/usr/bin/env python2
import sys
from scapy.all import *

pcap_filename = sys.argv[1]

packets = rdpcap(pcap_filename)

prev_time = packets[0].time
packet_number = 0

for pkt in packets:
	delta = pkt.time - prev_time
	print '{}    {}'.format(packet_number,  delta)
	prev_time = pkt.time
	packet_number += 1

