#!/usr/bin/env perl
# This is a simple perl TCP socket server example from tutorialspoint.com
use strict;
use warnings;
use Socket;

use constant SOCK_DCCP      =>  6;
use constant IPPROTO_DCCP   => 33;

# use port 7890 as default
my $port = shift || 7890;
my $server = "localhost";  # Host IP running the server

# create a socket, make it reusable
socket(my $listen_sock, PF_INET, SOCK_DCCP, IPPROTO_DCCP)
  or die "Can't open socket $!\n";
#setsockopt($listen_sock, SOL_SOCKET, SO_REUSEADDR, 1)
#   or die "Can't set socket option to SO_REUSEADDR $!\n";

# bind to a port, then listen
bind( $listen_sock, pack_sockaddr_in($port, inet_aton($server)))
   or die "Can't bind to port $port! \n";

listen($listen_sock, 5) or die "listen: $!";
print "SERVER started on port $port\n";

# accepting a connection
my $client_addr;
while ($client_addr = accept(NEW_SOCKET, $listen_sock)) {
   # send them a message, close connection
   my $name = gethostbyaddr($client_addr, AF_INET );
   print NEW_SOCKET "Smile from the server";
   print "Connection recieved from $name\n";
   close NEW_SOCKET;
}
