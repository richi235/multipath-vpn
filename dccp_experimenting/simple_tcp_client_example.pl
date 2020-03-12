#!/usr/bin/env perl
# Simple tcp client in perl from tutorialspoint.com

use strict;
use warnings;
use Socket;

use constant SOCK_DCCP      =>  6;
use constant IPPROTO_DCCP   => 33;

my $server_port = shift || 7890;
my $server_ip = "localhost";

# create the socket, connect to the server_port
socket(my $con_sock, PF_INET, SOCK_DCCP, IPPROTO_DCCP)
   or die "Can't create a socket $!\n";

connect( $con_sock, pack_sockaddr_in($server_port, inet_aton($server_ip)))
   or die "Can't connect to server_port $server_port! \n";

my $line;
while ($line = <$con_sock>) {
   print "$line\n";
}
close $con_sock or die "close: $!";
