#!/usr/bin/env perl


=pod

=head1 NAME

Multipath VPN

=head1 Technical Overview

Multipath VPN is implemented without threads using 1 process and several Sessions.
Sessions are roughly comparable to event loops (see the POE doc for details).

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
To achive this all 5 seconds it calls I<reset_routing_table()> if needed.

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

use POE;
use POE::Wheel::UDP;
use POE
  qw(Component::Server::TCP Component::Client::TCP Filter::Block Filter::Stream);

use IO::File;
use IO::Interface::Simple;
use IO::Socket::INET;
use IO::Socket;

use Socket qw(IPPROTO_TCP TCP_NODELAY);
use Time::HiRes qw/gettimeofday tv_interval/;
use MIME::Base64;

# Constants
use constant TUN_MAX_FRAME => 4096;

# Ioctl defines
use constant TUNSETNOCSUM  => 0x400454c8;
use constant TUNSETDEBUG   => 0x400454c9;
use constant TUNSETIFF     => 0x400454ca;
use constant TUNSETPERSIST => 0x400454cb;
use constant TUNSETOWNER   => 0x400454cc;

# TUNSETIFF ifr flags
use constant IFF_TUN       => 0x0001;
use constant IFF_TAP       => 0x0002;
use constant IFF_NO_PI     => 0x1000;
use constant IFF_ONE_QUEUE => 0x2000;
use constant TUN_PKT_STRIP => 0x0001;

use constant STRUCT_IFREQ  => 'Z16 s';
use constant TUNNEL_DEVICE => '/dev/net/tun';

# Global Variables
my $sessions   = {};
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

my @interface_choosing_plan;
my $interface_choosing_state = 0;   # current array index
my $plan_length = 0;                # number of elements



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

        my @config = split( /\t/, $_ );

        if ( $config[0] && ( lc( $config[0] ) eq "link" ) )
        {
            $config->{links}->{ $config[1] } = {
                name    => $config[1],
                src     => $config[2],
                srcport => $config[3],
                dstip   => $config[4] || undef,
                dstport => $config[5] || undef,
                factor  => $config[6],

                lastdstip => $config[4] || undef,
                options   => $config[7] || "",
                curip     => "",
            };
        }
        elsif ( $config[0] && ( lc( $config[0] ) eq "local" ) ) {
            $config->{local} = {
                ip             => $config[1],
                subnet_size    => $config[2] || 24,
                mtu            => $config[3] || 1300,
                dstip          => $config[4],
                options        => $config[5],
            };
        }
        elsif ( $config[0] && ( lc( $config[0] ) eq "route" ) ) {
            push(
                @{ $config->{route} },
                {
                    to            => $config[1],
                    subnet_size   => $config[2],
                    gw            => $config[3],
                    table         => $config[4],
                    metric        => $config[5],
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

sub add_interface_to_plan
{
    my $session_id = shift;
    my $factor     = shift;

    # in case this call was wrong and the interface is already in the plan
    remove_interface_from_plan($session_id);

    push( @interface_choosing_plan, $session_id x $factor);
    $plan_length = @interface_choosing_plan;

    return;
}

sub remove_interface_from_plan
{
    my $session_id = shift;

    my @new_plan;

    for (@interface_choosing_plan)
    {
        if ( $_ != $session_id ) {
            push(@new_plan, $_);
        }
    }

    @interface_choosing_plan = @new_plan;

    $plan_length = @interface_choosing_plan;

    return;
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

=item 2. It starts a new UDP socket on the new interface ( I<using startUDPSocket()> )

=item 2. All the sessions are re-established

=back

=cut

sub handle_local_ip_change
{
    foreach my $curlink ( keys %{ $config->{links} } )
    {
        my $new_src_address = '';
        if ( my $curif =
            IO::Interface::Simple->new( $config->{links}->{$curlink}->{src} ) )
        {
            $new_src_address = $curif->address();
        }
        else
        {
            $new_src_address = $config->{links}->{$curlink}->{src};
        }

        my $restart = 0;

        if ( $new_src_address
            && ( $config->{links}->{$curlink}->{curip} ne $new_src_address ) )
        {
            $config->{links}->{$curlink}->{curip} = $new_src_address;
            print("IP Change for " . $config->{links}->{$curlink}->{src} . " !\n");

            $restart++;
        }

        if ($restart) {
            if ($config->{links}->{$curlink}->{cursession}) {
                $poe_kernel->call($config->{links}->{$curlink}->{cursession} => "terminate" );
            }
            startUDPSocket($curlink);
        }
        else {
            if ( $config->{links}->{$curlink}->{cursession}
              && ( $config->{links}->{$curlink}->{dstip}
                || $config->{links}->{$curlink}->{lastdstip} ))
            {
                $poe_kernel->post(
                    $config->{links}->{$curlink}->{cursession} => "send_through_udp" => "SES:"
                        . $curlink . ":"
                        . join( ",", keys %$lastseen ) );
            }
        }
    }
}

=pod

=head2 reset_routing_table( I<$up> )

Resets all routing table entries made by this programm.

=over

=item If called with parameter I<1> delete and set them again(acording to conf file).

=item If called with parameter I<0> delete them.

=back

=cut

sub reset_routing_table
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

# creates a new POE Session and does some other things
sub startUDPSocket
{
    my $link = shift;
    my $con  = $config->{links}->{$link};

    print( "Starting " . $link
      . " with source='" . $con->{curip} . "':" . $con->{srcport}
      . " and dst=" . ( $con->{dstip}   || "-" ) . ":" . ( $con->{dstport} || "-" ) . "\n" );

    # [UDP-Socket Session]
    # unique for each link
    POE::Session->create(
        inline_states => {
            _start => sub {
                my ( $kernel, $heap, $session, $con ) = @_[ KERNEL, HEAP, SESSION, ARG0 ];
                $heap->{con} = $con;

                my $bind  = ( $con->{options} =~ m,bind,i )  ? 1 : 0;
                my $reuse = ( $con->{options} =~ m,reuse,i ) ? 1 : 0;

                print( "Bind: " . $bind . " Reuse:" . $reuse . " "
                  . ( $con->{dstip}   || "-" ) . ":"
                  . ( $con->{dstport} || "-" ) . "\n" );

                eval {
                    $heap->{udp_socket} = new IO::Socket::INET(
                        PeerAddr  => $bind ? $con->{dstip}   : undef,
                        PeerPort  => $bind ? $con->{dstport} : undef,
                        LocalAddr => $con->{curip},
                        LocalPort => $con->{srcport},
                        ReuseAddr => $reuse ? 1 : 0,
                        Proto     => 'udp',
                    ) or die "ERROR in Socket Creation : $!\n";
                };

                # if the previous eval produced an error
                if ($@) {
                    print "Not possible: " . $@ . "\n";
                    return;
                }

                if ( $heap->{udp_socket} ) {
                    $heap->{sessionid} = $session->ID();
                    $sessions->{ $heap->{sessionid} } = {
                        heap   => $heap,
                        factor => $heap->{con}->{factor},
                        con    => $con,
                    };

                    add_interface_to_plan($heap->{sessionid}, $heap->{con}->{factor});

                    # select read registers a event to be called on read input on the socket
                    $kernel->select_read( $heap->{udp_socket}, "got_data_from_udp" );

                    if ($bind) {
                        unless ( defined( $heap->{udp_socket}->send("a") ) ) {
                            print "PostBind not worked: " . $! . "\n";
                        }
                    }
                }
                else {
                    my $retrytimeout = $config->{retrytimeout} || 30;
                    print "Binding to "
                        . $con->{curip} . ":"
                        . $con->{srcport}
                        . " not worked!\n";
                }

                $con->{cursession} = $heap->{sessionid};
            },
            _stop => sub {
                my ( $kernel, $heap, $session ) = @_[ KERNEL, HEAP, SESSION ];

                print( "Session term.\n");

                remove_interface_from_plan( $session->ID() );
                delete( $sessions->{ $session->ID() } );
            },
            got_data_from_udp => sub {
                my ( $kernel, $heap, $session ) = @_[ KERNEL, HEAP, SESSION ];

                my $curinput = undef;
                while ( defined( $heap->{udp_socket}->recv( $curinput, 1600 ) ) )
                {
                    $heap->{con}->{lastdstip}   = $heap->{udp_socket}->peerhost();
                    $heap->{con}->{lastdstport} = $heap->{udp_socket}->peerport();

                    if ($printdebug) {
                        print("Incoming datagram from '" . length($curinput) . "' Bytes\n");
                    }

                    if ($doPrepend) {
                        substr( $curinput, 0, length($doPrepend), "" );
                    }

                    if ($doCrypt) {
                        my $replace = substr( $curinput, 0, 200, "" );
                        $replace = join( "",
                            map { chr( ( ( ord($_) + 129 ) % 256 ) ) }
                              split( //, $replace ) );
                        $curinput = $replace . $curinput;
                    }

                    if ($doBase64) {
                        $curinput = decode_base64($curinput);
                    }

                    if ( !$no_dead_peer && ( substr( $curinput, 0, 4 ) eq "SES:" ) )
                    {
                        my $announcement = [ split( ":", $curinput ) ];
                        shift(@$announcement);
                        my $dstlink = shift(@$announcement);

                        $config->{$dstlink}->{lastdstip} = $heap->{con}->{lastdstip};
                        $config->{$dstlink}->{lastdstport} = $heap->{con}->{lastdstport};

                        my $myseen = [];

                        if ( my $tmp = shift(@$announcement) ) {
                            $myseen = [ split( ",", $tmp ) ];
                        }

                        $seen->{$dstlink} = scalar(@$myseen);

                        foreach my $curlink ( keys %{ $config->{links} } ) {
                            $config->{links}->{$curlink}->{active} =
                              scalar( grep { $curlink eq $_ } @$myseen )
                              ? 1
                              : 0;
                        }

                        print( "Session announcement "
                          . length($curinput)
                          . " bytes: "
                          . $dstlink
                          . " and seen links "
                          . join( ",", @$myseen ) . "\n" );
                    }
                    else {
                        if ($tuntap_session) {
                            $kernel->call( $tuntap_session => "put_into_tun_device", $curinput );
                        }
                    }
                }
            },
            send_through_udp => sub {
                my ( $kernel, $heap, $input ) = @_[ KERNEL, HEAP, ARG0 ];

                my $to = undef;
                if ( $heap->{con}->{dstip} && $heap->{con}->{dstport} ) {
                    if ( my $dstip = inet_aton( $heap->{con}->{dstip} ) ) {
                        $to = pack_sockaddr_in( $heap->{con}->{dstport}, $dstip );
                    }
                    else {
                        print( "Unable to reslove " . $heap->{con}->{dstip} . "\n");
                    }
                }
                elsif ($heap->{con}->{lastdstip}
                    && $heap->{con}->{lastdstport} )
                {
                    if ( my $dstip = inet_aton( $heap->{con}->{lastdstip} ) ) {
                        $to = pack_sockaddr_in( $heap->{con}->{lastdstport},
                            inet_aton( $heap->{con}->{lastdstip} ) );
                    }
                    else {
                        print "Unable to reslove "
                          . $heap->{con}->{lastdstip} . "\n";
                    }
                }

                if ($to) {
                    my $count = 0;

                    if ($doBase64) {
                        $input = encode_base64( $input, "" );
                    }

                    if ($doCrypt) {
                        my $replace = substr( $input, 0, 200, "" );
                        $replace = join( "",
                            map { chr( ( ( ord($_) + 127 ) % 256 ) ) }
                              split( //, $replace ) );
                        $input = $replace . $input;
                    }

                    if ($doPrepend) {
                        $input = $doPrepend . $input;
                    }

                    if ( !defined( $heap->{udp_socket}->send( $input, 0, $to ) ) ) {
                        print "X";
                    }
                }
                else {
                    print( $heap->{con}->{name} . ": Cannot send: no dst ip/port.\n");
                }
            },
            terminate => sub {
                my ( $kernel, $heap, $session ) = @_[ KERNEL, HEAP, SESSION ];

                print( "Socket terminated" . "\n" );

                remove_interface_from_plan( $session->ID() );
                delete( $sessions->{ $session->ID() } );

                $kernel->select_read( $heap->{udp_socket} );

                close( $heap->{udp_socket} );
                delete( $heap->{udp_socket} );
            },
        },
        args => [$con],
    );
}

####### Section 1 END: Function Definitions #############

parse_conf_file();


# [Local IP Check Session]
# Here to detect and handle local IP changes.
# Starts a loop after creation which calls handle_local_ip_change() every second
POE::Session->create(
    inline_states => {
        _start => sub {
            my ( $kernel, $heap ) = @_[ KERNEL, HEAP ];

            $kernel->yield("loop");
        },
        loop => sub {
            my ( $kernel, $heap ) = @_[ KERNEL, HEAP ];

            handle_local_ip_change();
            $kernel->delay( loop => 1 );
        },
    },
);

# [Target Reachability Check (TRC) Session]
# this Sessions executes loop all 5 seconds and checks if the used
# connections are reachable.(Using the $seen and $lastseen variables)
# If not, it takes the interface down (using reset_routing_table() ).
POE::Session->create(
    inline_states => {
        _start => sub {
            my ( $kernel, $heap ) = @_[ KERNEL, HEAP ];
            $kernel->yield("loop");
        },
        loop => sub {
            my ( $kernel, $heap ) = @_[ KERNEL, HEAP ];

            $lastseen = $seen;

            if ( scalar( grep( $lastseen->{$_}, keys(%$lastseen)) ) )
            {
                unless ($up) {
                    reset_routing_table(1);
                }
                $up++;
            }
            else {
                if ($up) {
                    reset_routing_table(0);
                }
                $up = 0;
            }

            $seen = {};
            $kernel->delay( loop => 5 );
        },
    },
);

# [TUN-Interface Session]
# simplified explanation of this session:
# (_start is triggered by creation of this session therefore
# directly "here" before kernel->run() )
# when handling the   **start** event   :
## doing a lot of stuff with ifconfig and iptables
## possibly setting an interface and corresponding rules
POE::Session->create(
    inline_states => {
        _start => sub {
            my ( $kernel, $heap ) = @_[ KERNEL, HEAP ];

            my $dotun =
              (      ( $config->{local}->{ip} =~ /^[\d\.]+$/ )
                  && ( $config->{local}->{options} !~ /tap/ ) ) ? 1 : 0;

            # this creates the tun device
            $heap->{tun_device} = new IO::File( TUNNEL_DEVICE, 'r+' )
              or die "Can't open " . TUNNEL_DEVICE . ": $!";

            $heap->{ifr} = pack( STRUCT_IFREQ,
                $dotun ? 'tun%d' : 'tap%d',
                $dotun ? IFF_TUN : IFF_TAP );

            ioctl $heap->{tun_device}, TUNSETIFF, $heap->{ifr}
              or die "Can't ioctl() tunnel: $!";

            $heap->{interface} = unpack STRUCT_IFREQ, $heap->{ifr};

            print( "Interface " . $heap->{interface} . " up!\n");

                  # regex check if the configured ip is an ip
            if ( $config->{local}->{ip} =~ /^[\d\.]+$/ )
            {
                system( "ifconfig "
                      . $heap->{interface} . " "
                      . $config->{local}->{ip} . "/"
                      . $config->{local}->{subnet_size}
                      . " up" );
            }
            else {    # if not do something obscure with bridge interfaces
                system( "ifconfig " . $heap->{interface} . " up" );
                system( "brctl", "addif", $config->{local}->{ip}, $heap->{interface} );
            }

            if (( $config->{local}->{dstip} )) {
                system( "ifconfig "
                  . $heap->{interface}
                  . " dstaddr "
                  . $config->{local}->{dstip} );
            }

            if (( $config->{local}->{mtu} )) {
                system( "iptables -A FORWARD -o "
                  . $heap->{interface}
                  . " -p tcp -m tcp --tcp-flags SYN,RST SYN -m tcpmss --mss "
                  . ( $config->{local}->{mtu} - 40 )
                  . ":65495 -j TCPMSS --clamp-mss-to-pmtu" );
            }

            system( "ifconfig " . $heap->{interface} . " mtu " . $config->{local}->{mtu} );

            $kernel->select_read( $heap->{tun_device}, "got_packet_from_tun_device" );
            $tuntap_session = $_[SESSION];
        },
        got_packet_from_tun_device => sub {
            my ( $kernel, $heap, $socket ) = @_[ KERNEL, HEAP, ARG0 ];

            if ( $socket != $heap->{tun_device} ) {
                die();
            }

            # read data from the tun device
            my $buf = "";
            while ( sysread( $heap->{tun_device}, $buf , TUN_MAX_FRAME ) )
            {
                foreach my $session_id (
                    sort( {( $sessions->{$a}->{tried} || 0 )
                          <=> ( $sessions->{$b}->{tried} || 0 ) }
                      keys( %$sessions))
                  )
                {
                    # Problem: Was mache ich wenn aktuelles interface down ist?
                    #   • Dann muss ich ja zum nächsten interface gehen
                    #   • braucht also ne schleife
                    #   • Was wäre dann die schleifenbedingung?
                    #     • Evtl true und dann mit last rausspringen wenn es geklappt hat
                    #     • Also genauso wie es jetzt auch ist
                    #       jo, würde gehn
                    #       • Wobei Problem: das könnte sein das es nie terminiert
                    #         • aktuell ist es ja so, dass er nach $Anzahl sessions sicher terminiert
                    #           Also als bedingung $i <= $plan_length ?
                    #           • so geht man sicher das jeder "slot" einmal probiert wird
                    #             klingt eigentlich gut, ja
                    #
                    #  2. Gedanke: Es kann ja sein, dass der ->{con}->{active} test überhaupt nix bringt
                    #      • Weil es wird nur mega selten geupdated
                    #        • nur in der udp_socket_session beim event got_data_from_udp
                    #        • und nur wenn die received message mit "SES: " anfängt (Session announcement)
                    #        • Wobei hmm, sagt ein announcment immer was über alle links?
                    #          Weil die gegenstelle ja auch "beide" sieht und was darüber erzählen kann
                    #          • Ja okay in so fern kann es eigentlich doch ganz sinnvoll sein
                    #            • Man sollte sich halt echt mal die session announcments anschauen zur laufzeit
                    #            • Aber es kann echt sein das der server da erzählt, was er für sessions sieht, also alle
                    #            • In so fern wäre es auch echt sinnvoll, an der stelle dann den interface_plan zu aktualisieren
                    #              Ja, demnächst, eins nach dem anderen


                    if ($sessions->{$session_id}->{factor})
                    {
                        $sessions->{$session_id}->{tried} += ( 1 / $sessions->{$session_id}->{factor} );
                    }
                    unless ( $no_dead_peer || $sessions->{$session_id}->{con}->{active} )
                    {
                        next;
                    }

                    $kernel->call( $session_id, "send_through_udp", $buf );
                    last;
                }
            }
        },
        put_into_tun_device => sub {
            my ( $kernel, $heap, $buf ) = @_[ KERNEL, HEAP, ARG0 ];

            # write data of $buf into the tun-device
            my $size = syswrite( $heap->{tun_device}, $buf );

            unless ( $size == length($buf) )
            {
                print $size . " != " . length($buf) . "\n";
            }
        },
    }
);

$poe_kernel->run();
