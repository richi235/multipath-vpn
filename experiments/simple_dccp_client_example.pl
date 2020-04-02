#!/usr/bin/env perl
# Simple tcp client in perl from tutorialspoint.com

use v5.10;
use strict;
use warnings;
use Socket;

## Constants for DCCP
use constant SOCK_DCCP      =>  6;
use constant IPPROTO_DCCP   => 33;
use constant DCCP_SOCKOPT_CCID_TX_INFO  => 192;
use constant SOL_DCCP       => 269;
use constant SIOCOUTQ       => 21521;

my $server_port = shift || 7890;
my $server_ip = "localhost";

# create the socket, connect to the server_port
socket(my $con_sock, PF_INET, SOCK_DCCP, IPPROTO_DCCP)
   or die "Can't create a dccp socket $!\n";

connect( $con_sock, pack_sockaddr_in($server_port, inet_aton($server_ip)))
   or die "Can't connect to server_port $server_port! \n";

my $line;
while ($line = <$con_sock>) {
   print "$line\n";
   my $dccp_info_struct = getsockopt($con_sock, 
        SOL_DCCP,
        DCCP_SOCKOPT_CCID_TX_INFO,
   );
   if (!defined($dccp_info_struct)){
       say $!;
   }

   my ($send_rate, $recv_rate, $calc_rate, $srtt, $loss_event_rate, $rto, $ipi)
       = unpack('QQLLLLL', $dccp_info_struct);

   say($send_rate);
   say($srtt);
}
close $con_sock or die "close: $!";
