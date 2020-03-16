#!/usr/bin/env perl

use warnings;
use strict;

use IO::Socket;
use POE qw(Wheel::SocketFactory Wheel::ReadWrite);

use constant SOCK_DCCP      =>  6;
use constant IPPROTO_DCCP   => 33;

POE::Session->create(
  inline_states => {
    _start => sub {
      # Start the server.
      $_[HEAP]{server} = POE::Wheel::SocketFactory->new(
        BindPort       => 12345,
        SuccessEvent   => "on_client_accept",
        FailureEvent   => "on_server_error",
        SocketDomain   => PF_INET,
        SocketType     => SOCK_DCCP,
        SocketProtocol => IPPROTO_DCCP,
      );
    },
    on_client_accept => sub {
      # Begin interacting with the client.
      my $client_socket = $_[ARG0];
      my $io_wheel = POE::Wheel::ReadWrite->new(
        Handle => $client_socket,
        InputEvent => "on_client_input",
        ErrorEvent => "on_client_error",
      );
      $_[HEAP]{client}{ $io_wheel->ID() } = $io_wheel;
    },
    on_server_error => sub {
      # Shut down server.
      my ($operation, $errnum, $errstr) = @_[ARG0, ARG1, ARG2];
      warn "Server $operation error $errnum: $errstr\n";
      delete $_[HEAP]{server};
    },
    on_client_input => sub {
      # Handle client input.
      my ($input, $wheel_id) = @_[ARG0, ARG1];
      $input =~ tr[a-zA-Z][n-za-mN-ZA-M]; # ASCII rot13
      $_[HEAP]{client}{$wheel_id}->put($input);
    },
    on_client_error => sub {
      # Handle client error, including disconnect.
      my $wheel_id = $_[ARG3];
      delete $_[HEAP]{client}{$wheel_id};
    },
  }
);

POE::Kernel->run();
exit;
