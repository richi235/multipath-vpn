#!/usr/bin/env perl


=pod

=head1 NAME

Multipath VPN

=head1 Technical Overview

Multipath VPN is implemented without threads using 1 process and several Sessions.
Sessions group semantically related event handlers (see the POE doc for details).
(Often related by operatingg on the same object.)

At any point in time the I<number of event loops> in Multipath VPN is constant
and calulated as follows:

I<3> + B<n> ; with B<n> = I<Number of paths/links to Server>

The following section explains how this formula is combined and what exactly these
Sessions do.

=head2 The Sessions

The I<name tags> used here are also labled in the source code. In the comments above
every B<POE::Session-E<gt>create(> line.


=head3 [Local IP Check Session]

This Session is created B<at startup> exists permanentely and is I<unique> for one running instance of multipath vpn.
Once a seconds it calls I<handle_local_ip_change()>.
The sessions purpose is to ensure multipath vpn continues working even if
interface IP address changes (of server or client both are handled) happen.

=head3 [Target Reachability Check (TRC) Session]

This Session is created B<at startup> exists permanentely and is I<unique> for one running instance of multipath vpn.
Every five seconds it checks if the server is reachable via all configured links.
If one goes down he deconfigures the corresponding interface.
This session keeps checking if the target is reachable, if it is reachable again,
the connection will be reestablished.
To achive this all 5 seconds it calls I<set_via_tunnel_routes()> if needed.

=head3 [TUN-Interface Session]

This Session is created B<at startup> exists permanentely and is I<unique> for one running instance of multipath vpn.
Running on one node recieving and accepting the multipath-vpn tunnel packets from the other node.
This session also is responsible for unpacking the contained packets and forwarding it to the clients in the local net.
The session also creates the tun/tap interface when it is created.

=head3 [UDP-Socket Session]

One Instance of Session is B<unique for for every UDP Socket> (which is unique for every link). Therefore I<several instances>
of this session can exist and this is the non-static B<n> in the formula above.
It handles all events corresponding to sending packets to other Multipath VPN nodes.
Therefore this sessions takes TCP/UDP packets from the tun/tap interface, wraps them into UDP
and delivers them to the other multipath VPN node configured in the conf file.

=head1 Doc of some Functions:

=cut





# Includes
use strict;
use warnings;
use v5.10;

use POE;
use POE::Wheel::UDP;
use POE
  qw(Component::Server::TCP Component::Client::TCP Filter::Block XS::Loop::Poll Filter::Stream);

use IO::File;
use IO::Interface::Simple;
use IO::Socket;
use Socket;

use Time::HiRes qw/gettimeofday tv_interval/;
use MIME::Base64;
use Term::ANSIColor;

# Constants
use constant TUN_MAX_FRAME => 4096;

## Ioctl defines
use constant TUNSETNOCSUM  => 0x400454c8;
use constant TUNSETDEBUG   => 0x400454c9;
use constant TUNSETIFF     => 0x400454ca;
use constant TUNSETPERSIST => 0x400454cb;
use constant TUNSETOWNER   => 0x400454cc;

## TUNSETIFF if_init_request flags
use constant IFF_TUN       => 0x0001;
use constant IFF_TAP       => 0x0002;
use constant IFF_NO_PI     => 0x1000;
use constant IFF_ONE_QUEUE => 0x2000;
use constant TUN_PKT_STRIP => 0x0001;

use constant STRUCT_IFREQ  => 'Z16 s';
use constant TUNNEL_DEVICE => '/dev/net/tun';

## Constants for DCCP
use constant SOCK_DCCP      =>  6;
use constant IPPROTO_DCCP   => 33;


# Global Variables
my $sessions   = {};
my @subtun_sessions = ();
my $doCrypt    = 0;
my $doPrepend  = undef;    # "abcdefghikjlmnopqrstuvwxyz";
my $doBase64   = 0;
my $printdebug = 0;

$| = 1;                    # disable terminal output buffering
my $looktime   = 5;
my $no_dead_peer = 0;
my $up         = 0;

my $tuntap_session = undef;

my $config   = {};
my $seen     = {};
my $lastseen = {};

my $dccp_Texit  = 0;
my $dccp_Tentry = 1;

### Signal Handlers ###
$SIG{INT} = sub { die "Caught a SIGINT Signal. Current Errno: $!" };



####### Section 1 START: Function Definitions #############


# modifies the global variable $config (a dictionary)
# highly impure
# uses the first command line argument or "/etc/multivpn.cfg" as conf file
# needs no arguments
sub parse_conf_file
{
    # open config file
    open( my $conf_file, "<", $ARGV[0] || "/etc/multivpn.cfg" )
    || die "Config file not found: " . $!;

    # read and parse config file (linewise)
    while (<$conf_file>)
    {
        chomp($_);
        s/\#.*$//gi;      # delete all comments
        next if m,^\s*$,; # next if we're in a now deleted line

        my @line = split( /\t/, $_ );

        if ( $line[0] && ( lc( $line[0] ) eq "link" ) )
        {
            $config->{subtunnels}->{ $line[1] } = {
                name    => $line[1],
                src     => $line[2],
                srcport => $line[3],
                dstip   => $line[4] || undef,
                dstport => $line[5] || undef,
                factor  => $line[6],

                lastdstip => $line[4] || undef,
                options   => $line[7] || "",
                curip     => "",
            };
        }
        elsif ( $line[0] && ( lc( $line[0] ) eq "local" ) ) {
            $config->{local} = {
                ip             => $line[1],
                subnet_size    => $line[2] || 24,
                mtu            => $line[3] || 1300,
                dstip          => $line[4],
                options        => $line[5],
            };
        }
        elsif ( $line[0] && ( lc( $line[0] ) eq "route" ) ) {
            push(
                @{ $config->{route} },
                {
                    to            => $line[1],
                    subnet_size   => $line[2],
                    gw            => $line[3],
                    table         => $line[4],
                    metric        => $line[5],
                });
        }
        elsif (m,^\s*$,) {
        }
        else {
            die "Bad config line: " . $_;
        }
    }
    close($conf_file);
}


sub printDebug
{
    print "\n" . join(
        "\t",
        map {
                $_ . "="
              . ( $sessions->{$_}->{high}        || "-" ) . "("
              . ( $sessions->{$_}->{outcount}    || "-" ) . "/" . ""
              . ( $sessions->{$_}->{curoutcount} || "-" ) . "/" . ""
              . ( $sessions->{$_}->{tried}       || "-" ) . ")"
        } keys %$sessions
    ) . "\n";
}

=pod

=head2 handle_local_ip_change()

Detects ip changes of the local network interfaces used for listening for or connecting to another
multipath vpn instance.
This can handle a server changing his ip (will then rebuild his connection to the clients and update them).
as well as a ip change of a client (after all there is no strict server client distinction in the multipath vpn
model, there are just node communicating).
If a IP change is detected the following is done:

=over

=item 1. It write's a message to the controling terminal

=item 2. The sessions using the old interface are killed

=item 2. It starts a new UDP socket on the new interface ( I<using setup_udp_subtunnel()> )

=item 2. All the sessions are re-established

=back

=cut

sub handle_local_ip_change
{
    foreach my $cur_subtunnel ( keys %{ $config->{subtunnels} } )
    {
        my $new_src_address = '';
        if ( my $curif =
            IO::Interface::Simple->new( $config->{subtunnels}->{$cur_subtunnel}->{src} ) )
        {
            $new_src_address = $curif->address();
        }
        else
        {
            $new_src_address = $config->{subtunnels}->{$cur_subtunnel}->{src};
        }

        my $restart_subtunnel = 0;

        if ( $new_src_address  # when new IP != old IP: store new IP in relevent $config key
            && ( $config->{subtunnels}->{$cur_subtunnel}->{curip} ne $new_src_address ) )
        {
            $config->{subtunnels}->{$cur_subtunnel}->{curip} = $new_src_address;
            print("IP Change for " . $config->{subtunnels}->{$cur_subtunnel}->{src} . " !\n");

            $restart_subtunnel++;
        }
        if ($restart_subtunnel) {
            # Kill the old session (of the no longer existing IP) and create a new one:
            if ($config->{subtunnels}->{$cur_subtunnel}->{cursession}) {
                $poe_kernel->call($config->{subtunnels}->{$cur_subtunnel}->{cursession} => "terminate" );
            }
            setup_udp_subtunnel($cur_subtunnel);
        }
        else {
            # When everything OK only send status update
            if ( $config->{subtunnels}->{$cur_subtunnel}->{cursession}
              && ( $config->{subtunnels}->{$cur_subtunnel}->{dstip}
                || $config->{subtunnels}->{$cur_subtunnel}->{lastdstip} ))
            {   # Send a status info to peer
                $poe_kernel->post(
                    $config->{subtunnels}->{$cur_subtunnel}->{cursession} => "send_through_udp" => "SES:"
                        . $cur_subtunnel . ":"
                        . join( ",", keys %$lastseen ) );
            }
        }
    }
}

=pod

=head2 set_via_tunnel_routes( I<$up> )

Sets routes to networks that are reachable via the tunnel (according to conf file).
Uses the ip command.

=over

=item If called with parameter I<1> delete and set them again(acording to conf file).

=item If called with parameter I<0> delete them.

=back

=cut

sub set_via_tunnel_routes
{
    my $up = shift;

    foreach my $current_route ( @{ $config->{route} } )
    {
        my $shell_command =
            "ip route delete "
          . $current_route->{to} . "/"
          . $current_route->{subnet_size}
          . (
            defined( $current_route->{metric} )
            ? " metric " . $current_route->{metric}
            : "")
          . ( $current_route->{table}
              ? " table " . $current_route->{table} :
              "" );

        print( $shell_command. "\n");
        system($shell_command);

        $shell_command =
            "ip route "
          . ( $up ? "add" : "delete" ) . " "
          . $current_route->{to} . "/"
          . $current_route->{subnet_size} . " via "
          . $current_route->{gw}
          . ( defined( $current_route->{metric} )
            ? " metric " . $current_route->{metric}
            : "")
          . ( $current_route->{table}
              ? " table " . $current_route->{table}
              : "" );

        print( $shell_command . "\n" );
        system($shell_command);
    }
}

sub send_scheduler
{
    my ( $kernel, $heap ) = @_[ KERNEL, HEAP];

    # read data from the tun device
    my $buf;
    while ( sysread( $heap->{tun_device}, $buf , TUN_MAX_FRAME ) )
    {
        # We're finally sending the packet
        $kernel->call( $subtun_sessions[0], "on_data_to_send", $buf );
    }
}

# Receives from a subtunnel and puts into tun/tap device
sub subtun_receive
{
    my ( $heap, $buf ) = @_[ HEAP, ARG0 ];

    # write data of $buf into the tun-device
    syswrite( $heap->{tun_device}, $buf );

}


sub create_tun_interface
{
    my $heap = shift;

    my $dotun =
        (      ( $config->{local}->{ip} =~ /^[\d\.]+$/ )
               && ( $config->{local}->{options} !~ /tap/ ) ) ? 1 : 0;

    $heap->{tun_device} = new IO::File( TUNNEL_DEVICE, 'r+' )
        or die "Can't open " . TUNNEL_DEVICE . ": $!";

    my $if_init_request = pack( STRUCT_IFREQ,
                         $dotun ? 'tun%d' : 'tap%d',
                         $dotun ? IFF_TUN : IFF_TAP );

    ioctl($heap->{tun_device}, TUNSETIFF, $if_init_request)
        or die "Can't ioctl() tunnel: $!";

    $heap->{tun_if_name} = unpack(STRUCT_IFREQ, $if_init_request);
    print( "Interface " . $heap->{tun_if_name} . " up!\n");
}

# This: (via ifconfig and iptables commands)
#   1. gives the tun interface an ip and defines it's subnet
#   2. ( if necesarry:  makes it part of a bridge or defines point2point interface)
#   3. configures pmtu clamping (via iptables)
#   4. configures the interface mtu
sub config_tun_interface
{
    my $heap = shift;

    # Set ip and subnet on our tun/tap interface
    if ( $config->{local}->{ip} =~ /^[\d\.]+$/ )  # regex check if the configured subtunnel source ip is an valid ip
    {
        system( "ifconfig "
                . $heap->{tun_if_name} . " "
                . $config->{local}->{ip} . "/"
                . $config->{local}->{subnet_size}
                . " up" );
    }
    else {
    # if not do something obscure with bridge interfaces
        system( "ifconfig " . $heap->{tun_if_name} . " up" );
        system( "brctl", "addif", $config->{local}->{ip}, $heap->{tun_if_name} );
    }

    if (( $config->{local}->{dstip} )) {
        system( "ifconfig "
            . $heap->{tun_if_name}
            . " dstaddr "
            . $config->{local}->{dstip} );
        # From ifconfig manpage:
        # dstaddr addr
        #
        # Set the remote IP address for a point-to-point link (such as PPP).
        # This keyword is now obsolete; use the pointopoint keyword instead.
    }

    # Set PMTU Clamping
    if (( $config->{local}->{mtu} )) {
        system( "iptables -A FORWARD -o "
            . $heap->{tun_if_name}
            . " -p tcp -m tcp --tcp-flags SYN,RST SYN -m tcpmss --mss "
            . ( $config->{local}->{mtu} - 40 )
            . ":65495 -j TCPMSS --clamp-mss-to-pmtu" );
    }

    # Set MTU
    system( "ifconfig " . $heap->{tun_if_name} . " mtu " . $config->{local}->{mtu} );

}

sub start_tun_session
{
    my ( $kernel, $heap ) = @_[ KERNEL, HEAP ];

    create_tun_interface($heap);
    config_tun_interface($heap);

    $kernel->select_read( $heap->{tun_device}, "got_packet_from_tun_device" );
    $tuntap_session = $_[SESSION];
}



sub create_dccp_listen_socket
{
    socket(my $listen_sock, PF_INET, SOCK_DCCP, IPPROTO_DCCP)
        or die "Can't open socket $!\n";

#    bind( $listen_sock, pack_sockaddr_in($port, inet_aton($server)))
#        or die "Can't bind to port $port! \n";

    listen($listen_sock, 5) or die "listen: $!";
}



sub setup_dccp_client
{

    my $subtunname = shift;
    my $new_subtunnel  = $config->{subtunnels}->{$subtunname};

    socket(my $con_sock, PF_INET, SOCK_DCCP, IPPROTO_DCCP)
       or die("Can't create a dccp socket $!\n");

    connect($con_sock, pack_sockaddr_in(12345, inet_aton($new_subtunnel->{dstip})))
        or die("DCCP Client: Can't connect to server! \n");

    say(colored("DCCP Client: ", 'bold green') . "Succesfully connected one subtunnel");

    POE::Session->create(
    inline_states => {
        _start => sub {
            $_[HEAP]{subtun_sock} = $_[ARG0];
            # Put this sessions id in our global array
            push(@subtun_sessions, $_[SESSION]->ID());
            $poe_kernel->select_read($_[HEAP]{subtun_sock}, "on_input");
        },
        on_input        => \&dccp_subtun_minimal_recv,
        on_data_to_send => \&dccp_subtun_minimal_send,
    },
    args => [$$con_sock],
    );

}


sub dccp_subtun_minimal_recv
{
    my $curinput = undef;
    $_[HEAP]{subtun_sock}->sysread($curinput, 1600);
    $_[KERNEL]->call($tuntap_session => "put_into_tun_device", $curinput);
}

sub dccp_subtun_minimal_send
{
    my $payload = $_[ARG0];
    $_[HEAP]->{subtun_sock}->syswrite($payload);
}

sub dccp_server_new_client {
    my $client_socket = $_[ARG0];

    ## Create a new session for every new dccp subtunnel socket
    POE::Session->create(
        inline_states => {
            _start    => sub {
                $_[HEAP]{subtun_sock} = $_[ARG0];
                # Put this session's id in our global array
                push(@subtun_sessions, $_[SESSION]->ID());
                say(colored("DCCP Server: ", 'bold green')
                       . "Succesfully accepted one subtunnel");
                $poe_kernel->select_read($_[HEAP]{subtun_sock}, "on_data_received");
            },
            on_data_received => \&dccp_subtun_minimal_recv,
            on_data_to_send => \&dccp_subtun_minimal_send,
        },
        args => [$client_socket],
    );
}
####### Section 1 END: Function Definitions #############

parse_conf_file();

# DCCP listen socket session
if ( $dccp_Texit) {
    POE::Session->create(
        # 1. Es will also gar keine listening address
        #    - Ja gut dann muss ich  die auch nicht aus der config holnem einfacher für mich^^
        # 2. Was mache ich mit dem port hole ich den aus der cnofig?
        #    Aber welchen? es können ja mehrere sein? für experiment ist es eigentlic hegal
        #    Entscheidung: Es bleibt bei 12345
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
        on_client_accept => \&dccp_server_new_client,
        on_server_error => sub {
            # Shut down server.
            my ($operation, $errnum, $errstr) = @_[ARG0, ARG1, ARG2];
            warn "Server $operation error $errnum: $errstr\n";
            delete $_[HEAP]{server};
        },
    }
    );
}

if ( $dccp_Tentry) {
    for my $subtun_name ( keys %{ $config->{subtunnels} } )
    {
        setup_dccp_client($subtun_name);
    }
}

# [TUN-Interface Session]
# simplified explanation of this session:
# (_start is triggered by creation of this session therefore
# directly "here" before kernel->run() )
# when handling the   **start** event   :
## doing a lot of stuff with ifconfig and iptables
## possibly setting an interface and corresponding rules
POE::Session->create(
    inline_states => {
        _start => \&start_tun_session,
        got_packet_from_tun_device => \&send_scheduler,
        put_into_tun_device => \&subtun_receive,
    }
);

set_via_tunnel_routes(1);

$poe_kernel->run();
