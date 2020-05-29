#!/usr/bin/env perl
# This is a bulk send dccp client
# It waits on the conn socket and whenever it's ready to send
# it sends 1420 bytes. Used to test out the maximum goodput a DCCP
# connection can deliver


use warnings;
use strict;

use IO::Socket;
use POE qw(Wheel::SocketFactory Wheel::ReadWrite);

use constant SOCK_DCCP      =>  6;
use constant IPPROTO_DCCP   => 33;

my $payload = "a" x 1400;

POE::Session->create(
  inline_states => {
    _start => sub {
      # Start the server.
      $_[HEAP]{server} = POE::Wheel::SocketFactory->new(
        RemoteAddress  => "127.0.0.1",
        RemotePort     => 12345,
        SuccessEvent   => "on_connection_established",
        FailureEvent   => "on_connection_error",
        SocketDomain   => PF_INET,
        SocketType     => SOCK_DCCP,
        SocketProtocol => IPPROTO_DCCP,
      );
    },
    on_connection_established => sub {
        # Begin interacting with the client.
        my $connection_socket = $_[ARG0];
        my $io_wheel = POE::Wheel::ReadWrite->new(
            Handle => $connection_socket,
            InputEvent => "on_input_from_server",
        );
        $_[HEAP]{our_wheel} = $io_wheel;
        $_[HEAP]{con_sock} = $connection_socket;

        POE::Kernel->yield("send_loop");
        # POE::Kernel->select_write($connection_socket, "handle_writable");
    },
    handle_writable => sub {
        $_[HEAP]{our_wheel}->put($payload)
    },
    send_loop => sub {
        $_[HEAP]{our_wheel}->put($payload);
        POE::Kernel->delay( send_loop => 0.00001);
    },
    on_input_from_server => sub {
        # Handle server input. (print it to terminal)
        my ($input, $wheel_id) = @_[ARG0, ARG1];
        print($input . "\n");
    },
    on_connection_error => sub {
        # Shut down server.
        my ($operation, $errnum, $errstr) = @_[ARG0, ARG1, ARG2];
        warn "Server $operation error $errnum: $errstr\n";
        delete $_[HEAP]{server};
    },
}
);

POE::Kernel->run();
exit;
