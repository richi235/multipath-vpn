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

I<1> + B<n> ; with B<n> = I<Number of paths/links to Server>

The following section explains how this formula is combined and what exactly these
Sessions do.

=head2 The Sessions

The I<name tags> used here are also labled in the source code. In the comments above
every B<POE::Session-E<gt>create(> line.


=head3 [TUN-Interface Session]

This Session is created B<at startup> exists permanentely and is I<unique> for one running instance of multipath vpn.
Running on one node recieving and accepting the multipath-vpn tunnel packets from the other node.
This session also is responsible for unpacking the contained packets and forwarding it to the clients in the local net.
The session also creates the tun/tap interface when it is created.

=head3 [Subtunnel-Socket Session]

One Instance of Session is B<unique for for every Subtunnel> (which is unique for every link). Therefore I<several instances>
of this session can exist and this is the non-static B<n> in the formula above.
It handles all events corresponding to sending packets to other Multipath VPN nodes.
Therefore this sessions takes TCP/UDP packets from the tun/tap interface, wraps them into UDP
and delivers them to the other multipath VPN node configured in the conf file.

=head3 [About the DCCP Info struct (CCID 3)]

To get the dccp internals via getsockopt on a dccp socket you need the following call:

  sock->Getsockopt(SOL_DCCP, DCCP_SOCKOPT_CCID_TX_INFO, &dccp_info, &dccp_info_len);

where dccp_info is a struct of the following type:

/**
 * struct ccid3_hc_tx_sock - CCID3 sender half-connection socket
 * @tx_x:		  Current sending rate in 64 * bytes per second
 * @tx_x_recv:		  Receive rate in 64 * bytes per second
 * @tx_x_calc:		  Calculated rate in bytes per second
 * @tx_rtt:		  Estimate of current round trip time in usecs
 * @tx_p:		  Current loss event rate (0-1) scaled by 1000000
 * @tx_s:		  Packet size in bytes
 * @tx_t_rto:		  Nofeedback Timer setting in usecs
 * @tx_t_ipi:		  Interpacket (send) interval (RFC 3448, 4.6) in usecs
 * @tx_state:		  Sender state, one of %ccid3_hc_tx_states
 * @tx_last_win_count:	  Last window counter sent
 * @tx_t_last_win_count:  Timestamp of earliest packet
 */
struct tfrc_tx_info {
    __u64 tfrctx_x;
    __u64 tfrctx_x_recv;
    __u32 tfrctx_x_calc;
    __u32 tfrctx_rtt;
    __u32 tfrctx_p;
    __u32 tfrctx_rto;
    __u32 tfrctx_ipi;
};

and:

#define DCCP_SOCKOPT_CCID_TX_INFO       192

### Way 1: Using pack() and unpack()

To create and read such a struct with perl we need, pack und unpack. More precise the
a pack template that describes the types:

__u64
__u64
__u32
__u32
__u32
__u32
__u32

which is in pack() template syntax: QQLLLLL

So creating a new nulled struct is: 

  my $dccp_info_struct = pack('QQLLLLL');

(because pack 0 pads if there's no input data)

=head3 [About the DCCP Info struct (CCID 2)]

/**  struct ccid2_tx_info (Congestion Control Infos)
 *
 * @tx_srtt:		     smoothed RTT estimate, scaled by 2^3
 * @tx_cwnd:                 max number of packets the path can handle
 * @tx_pipe:                 estimate of "in flight" packets
 * @buffer_fill              number of bytes in send buffer
 * @cur_mps                  current maximum packet size (in bytes)
 */
struct ccid2_tx_info {
	u32			tx_cwnd;
	u32			tx_srtt;
	u32                     tx_pipe;
	int                     buffer_fill;
	int                     cur_mps;
};

in pack() template syntax: LLLii


=head1 Doc of some Functions:

=cut




# Includes
use strict;
use warnings;
use v5.10;

use POE;
use POE
  qw(Wheel::SocketFactory XS::Loop::Poll);

use Log::Fast;
use Carp qw(longmess);
use IO::File;
use IO::Socket;

use Term::ANSIColor;
use Data::Dumper;
use Getopt::Long;
use Time::HiRes qw(time tv_interval);

use NetPacket::IP qw(:protos :versions);
use NetPacket::TCP;
use NetPacket::UDP;

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

use constant STRUCT_IFREQ  => 'Z16 s'; # byte representation template for pack()
use constant TUNNEL_DEVICE => '/dev/net/tun';

## Constants for DCCP
use constant SOCK_DCCP      =>  6;
use constant IPPROTO_DCCP   => 33;
use constant DCCP_SOCKOPT_CCID_TX_INFO  => 192;
use constant DCCP_SOCKOPT_GET_CUR_MPS   => 5;
use constant SOL_DCCP       => 269;
use constant SIOCOUTQ       => 21521;


# Global Variables
my $sessions   = {};
my $tuntap_session = undef;
my @subtun_sessions = ();
my @subtun_sockets  = ();
my $packet_scheduler;

$| = 1;                    # disable terminal output buffering
my $config   = {};
my $conf_file_name = "/etc/multivpn.cfg";
my $ccid_to_use = 2;

# ## Log::Fast Loglevels ## One out of:
# ERR
# WARN
# NOTICE
# INFO
# DEBUG
my $loglevel_txrx = 'WARN';
my $loglevel_algo = 'WARN';
my $loglevel_connect = 'NOTICE';
my $sched_algo = "afmt_fl";

my $help = 0;

# The Log::Fast (component wise) loggers
my $TXRXLOG;
my $ALGOLOG;
my $CONLOG;

my $dccp_Texit  = 0;

# (src_ip, src_port, dest_ip, dest_port) tupel is concatenated to a string (in exactly that order)
# and serves as key.
# An simple incrementally chosen int serves as value and flow id.
my %tupel_to_id;
my $max_flow_id = 0;

# The AFMT flow table:
# | Key     |  Value pair |
# | flow_id | (last_subtun_id, timestamp) |

# where last_subtun_id is the index in the @subtun_sessions and@subtun_sockets arrays

# How to represent in perl?
# naive approach:
#   hash : flow id --> array ref of last_subtunnel, timestamp
# will be using for now
my %flow_table;




### Signal Handlers ###
$SIG{INT} = sub { die "Caught a SIGINT Signal. Current Errno: $!" };
$SIG{QUIT} = \&toggle_sched_algo; # Strg + \ or Strg + |

####### Section 1 START: Function Definitions #############
sub parse_cli_args
{
    GetOptions('c|conf=s'     => \$conf_file_name,
               'lcon=s'       => \$loglevel_connect,
               'ltx=s'        => \$loglevel_txrx,
               'lalgo=s'      => \$loglevel_algo,
               'sched=s'      => \$sched_algo,
               'ccid=i'       => \$ccid_to_use,
               'h|help'       => \$help);

    if ( $help ) {
        say("This is the unofroest Multipath Tunneling prototype, for scientific testing. Science!
It supports the following cli params:
         'c|conf=s'     => \$conf_file_name, # /etc/multivpn.cfg is default
         'ccid=i'       => \$ccid_to_use,

         'sched=s'      => \$sched_algo, # 'rr' or 'afmt_fl' (default)
         'h|help'       => \$help

  ## Logging: (Levels: ERR | WARN | NOTICE | INFO | DEBUG)
         'lcon=s'       => \$loglevel_connect # default: NOTICE
         'ltx=s'        => \$loglevel_txrx, # default: WARN
         'lalgo=s'      => \$loglevel_algo, # default: WARN ");

        exit(0);
    }
}

# This is called on SIGQUIT (STRG+\) and toggles to the next sched algo (depending on current)
sub toggle_sched_algo
{
    if ( $sched_algo eq 'rr' ) {
        # Switch RR --> AFMT-FL
        $sched_algo = 'afmt_fl';
        $packet_scheduler = \&send_scheduler_afmt_fl;
        say("SWITCHER: Switched sched algo: RR --> AFMT_FL");
    } elsif ( $sched_algo eq 'afmt_fl' ) {
        # Switch AFMT-FL --> RR
        $sched_algo = 'rr';
        $packet_scheduler = \&send_scheduler_rr;
        say("SWITCHER: Switched sched algo: AFMT_FL --> RR");
    } else {
        die("WTF, should toggle sched algo but there's no sched algo I know of configured\n");
    }
}

sub init_loggers
{
    $TXRXLOG = Log::Fast->new({
        level           => $loglevel_txrx,
        type            => 'fh',
        fh              => \*STDOUT,
    });

    $ALGOLOG = Log::Fast->new({
        level           => $loglevel_algo,
        type            => 'fh',
        fh              => \*STDOUT,
    });

    $CONLOG = Log::Fast->new({
        level           => $loglevel_algo,
        type            => 'fh',
        fh              => \*STDOUT,
    });
}

# modifies the global variable $config (a dictionary)
# highly impure
# uses the first command line argument or "/etc/multivpn.cfg" as conf file
# needs no arguments
sub parse_conf_file
{
    # open config file
    open( my $conf_file, "<", $conf_file_name )
    || die "Config file not found: " . $!;

    # read and parse config file (linewise)
    while (<$conf_file>)
    {
        chomp($_);
        s/\#.*$//gi;      # delete all comments
        next if m,^\s*$,; # next if we're in a now deleted line

        my @line = split( /\s+/, $_ );

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
                tun_or_tap        => $line[4],
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

# returns: flow id
# param1: ref to packet byte string
sub get_flow_id
{

    my $packet_size = bytes::length($_[0]);
    $ALGOLOG->INFO("get_flow_id(): Packet size: $packet_size");
    # using $_[0] because with shift we would copy the whole packet, and that would be bad for performance
    # This removes the 4 byte TunTap header
    my $raw_ip_packet = bytes::substr($_[0], 4);

    # parse the packet
    my $ip_obj = NetPacket::IP->decode($raw_ip_packet);

    $ALGOLOG->DEBUG(Dumper($ip_obj));
    $ALGOLOG->DEBUG(IP_VERSION_IPv4); #dump the constant

    # Check if this is an IPv4 packet at all
    # if not return an error, we can not work with this here
    if ( $ip_obj->{ver} != IP_VERSION_IPv4 ) {
        $ALGOLOG->DEBUG("INFO: get_flow_id(): No IPv4 packet");
        return -2;
    }
    $ALGOLOG->INFO("get_flow_id(): IP Parsing succesfull: $ip_obj->{src_ip} : $ip_obj->{dest_ip} : $ip_obj->{proto}" );

    my ($src_port, $dest_port);

    if ( $ip_obj->{proto} == IP_PROTO_TCP ) {
        my $tcp_obj = NetPacket::TCP->decode($ip_obj->{data});
        $ALGOLOG->INFO("$tcp_obj->{src_port} : $tcp_obj->{dest_port}");
        $src_port  = $tcp_obj->{src_port};
        $dest_port = $tcp_obj->{dest_port};
    } elsif ($ip_obj->{proto} == IP_PROTO_UDP)
    {
        my $udp_obj = NetPacket::UDP->decode($ip_obj->{data});
        $ALGOLOG->INFO("$udp_obj->{dest_port} : $udp_obj->{src_port}");
        $src_port  = $udp_obj->{src_port};
        $dest_port = $udp_obj->{dest_port};
    } else {
        $ALGOLOG->ERR("Error: unparsable packet");
        return;
    }

    my $tupel_string = $ip_obj->{src_ip} . $src_port
        . $ip_obj->{dest_ip} . $dest_port;

    my $flow_id;
    if (defined( $flow_id = $tupel_to_id{$tupel_string})) {
        # yas, we know that flow, return its id
        $ALGOLOG->INFO("Found Flow id: $flow_id for $tupel_string");
        return $flow_id;
    } else {
        # create a new entry, return newly assigned id
        $max_flow_id++;
        $tupel_to_id{$tupel_string} = $max_flow_id;
        $ALGOLOG->INFO("Created new Flow id: $max_flow_id for $tupel_string");
        return $max_flow_id;
    }
}
# takes:  1. ref to applicable subtunnels array , 2. size of the packet to send
# returns: socket_id (int) of the chosen socket
sub select_adaptively
{
    my @applicable_subtun_hashes = @{$_[0]};
    my $packet_size = $_[1];

    my $opti_sock_id;
    my $min_weighted_fill = 1_000_000_000_000;

    if ( 0 == @applicable_subtun_hashes ) {
        $ALGOLOG->ERR("Error: select_adaptively() called with empty subtun_hashes array");
        exit(-1);
    }

    if ( 1 == @applicable_subtun_hashes) {
        # if only one subtunnel is applicable (no overtaking/reordering produced)
        # just return that
        $ALGOLOG->NOTICE("select_adaptively(): called with only 1 arg");
        return $applicable_subtun_hashes[0]->{sock_id};
    }

    for my $subtun_hash (@applicable_subtun_hashes) {
        my $weighted_fill =
            # Wie kriege ich jetzt hier SRTT und sock fill?
            #  - wäs wäre am performantesten?
            #  - habs ja vorher schonmal abgefragt für flow-awareness
            #  - evtl. mit reinwürgen in das @applicable_subtun_hashes array
            #    - ja why not, immernoch billiger als syscall 2 mal machen
            ( ( ($subtun_hash->{sock_fill}*$subtun_hash->{sock_fill}) + $packet_size) /
                  ($subtun_hash->{send_rate} || 1) )
            * $subtun_hash->{srtt};
#        say(colored($weighted_fill, "bold red"));
        $ALGOLOG->NOTICE("select_adaptively(): sock_id: $subtun_hash->{sock_id}"
                           . " | srtt:" . $subtun_hash->{srtt}/1000 . "ms"
                           . " | send_rate:" . ($subtun_hash->{send_rate}) . " (B/s)"
#                           . " | calc send_rate:" . ($subtun_hash->{calc_rate})/1000 . "kB/s"
                           . " | sock_fill: $subtun_hash->{sock_fill} Byte"
                           . " | resulting weighted_fill: $weighted_fill");

        if ( $weighted_fill <= $min_weighted_fill) {
            $min_weighted_fill = $weighted_fill;
            $opti_sock_id = $subtun_hash->{sock_id};
        }
    }
    $ALGOLOG->NOTICE("selected sock: $opti_sock_id, with weighted_fill: $min_weighted_fill");
    return $opti_sock_id;
}
# Takes care of all the error handling and the unpack()
# + the idiosyncratic getsockopt parameters
sub dccp_get_tx_infos
{
    my $socket_id = shift;
    my $sock = $subtun_sockets[$socket_id];
    my $dccp_info_struct = getsockopt($sock, SOL_DCCP, DCCP_SOCKOPT_CCID_TX_INFO);
    $ALGOLOG->ERR($! . "\n" . longmess()) if (!defined($dccp_info_struct));
    my $sock_hash;

    if ( $ccid_to_use == 3) {
        my ($send_rate, $recv_rate, $calc_rate, $srtt, $loss_event_rate,
            $rto, $ipi)
            = unpack('QQLLLLL', $dccp_info_struct);
        my $sock_fill = get_sock_sendbuffer_fill($sock);
        $sock_hash = {
            sock_id     => $socket_id,
            srtt        => $srtt,   # in μs (10^-6)
            send_rate   => $send_rate >> 6,
            sock_fill   => $sock_fill,
        };
    } elsif ($ccid_to_use == 2) {
        # TODOs:
        # * oben struct definition für tx_info struct hinschribene und unpack() templete raussuchen
        # * unpack hier machen
        # * überlegen wie ich das mit den return values hin geschichtel
        # * linux source lesen, sind ccid2 werte iwie scaliert?
        my ($cwnd, $srtt, $pipe, $buffer_fill, $cur_mps)
            = unpack('LLLii', $dccp_info_struct);
        $sock_hash = {
            sock_id     => $socket_id,
            srtt        => ($srtt * 1_000) >> 3,  # smoothed RTT estimate, scaled by 2^3
                           # converted to μs
            send_rate   => $cwnd,
            sock_fill   => $buffer_fill,
        };
    } else {
        die("dccp_get_tx_infos(): unknown ccid used\n");
    }

    say(colored("send_rate/cwnd: " . ($sock_hash->{send_rate}) . " (B/s)"  #  / 64  / 1024
                    # . " | peer recv_rate:" . ($recv_rate >> 16) . "kB/s"
                    . " | SRTT: " . $sock_hash->{srtt} . "μs or ms*8"
                    . " | sock_fill: " . $sock_hash->{sock_fill}
                    # . " | ccwnd: " . (($send_rate >> 6)*($srtt/1_000_000))/1_000 . "kB"
                    , "bold blue"));
    # I decided to not print the calculated send_rate because it was almost always 0 in my experiments

    return $sock_hash;
}



# TODOS:
#  [x]subtun stats mit in ds array mit rein wursteln
#     - hash struktur überlegen
#       - was brauche ich?
#         - SRTT
#         - cwnd/send rate
#         - sock_fill
#         - packe_size
#     - hash struktur dokumentieren
#     - hash jedes mal bauen/initialisieren
#     - hash reintun
#     - evtl. dinge sinnvoll umbennenn
#     - wegen packet size:
#       - wie kriege ich die am besten?
#       - ganzes paket mitgeben? oder besesr vorher messen und mit rein in den hash?
#         - gute frage
#           - so vom code style, deskriptiven stil wärs egientlich schöner vorher
#           - okay also vorher
#   * alles testen
#   * STARTED nochmal verstehen was die stats alle machen/passen die
#     - brauch ich die estimated oder die normale send rate? 
#   * mtu problem fixen/besser verstehen
#  [x]viel mehr logging überall einbauen
#  [x]evtl. über modulweises logging nachdenken
sub send_scheduler_afmt_fl
{
    my $subtun_count = @subtun_sockets;

    # When no subtunnels available, don't work and returning
    # Maybe we are still in warmup phase
    if ( $subtun_count == 0) {
        $ALGOLOG->WARN("send_scheduler_afmt_fl called with no subtunnels??? not sending, dropping");
        return;
    }

    # uses our own flow tracking system
    my $flow_id = get_flow_id($_[0]);

    # flow id -2 means it was no proper IPv4 packet, print error message and return
    # We don't forward non-ipv4 traffic currently
    if ( $flow_id == -2) {
        $ALGOLOG->WARN("WARNING: send_scheduler_afmt_fl(): payload ist no IPv4 packet, dropping it\n");
        return;
        # just returning without sending the packet is equivalent to droppning it
    }

    $ALGOLOG->NOTICE("\nsend_scheduler_afmt_fl() called with $subtun_count sockets, succesfully got flow id: $flow_id");

    # say("Current flow id: $flow_id" . "\n Flow table: " . Dumper(%flow_table));
    # If packet is part of a known flow:
    if ( defined (my $value_array = $flow_table{$flow_id})) { 
        my $last_sock_index = $value_array->[0]; # the index to the global subtunnel and sock arrays

        # the time stamp of when the last packet of this flow was send
        my $last_send_time = $value_array->[1];

        # How to calculate times?
        # Is basic perl time precise enough? do i need a special high res module? --> Time::HiRes
        my $now = time();
        my $delta = $now - $last_send_time; # delta in seconds (float with 10^-6 accuracy (microseconds))

        my $last_sock_hash = dccp_get_tx_infos($last_sock_index);

        my @applicable_subtun_hashes;
        push(@applicable_subtun_hashes, $last_sock_hash);

        for (my $i = 0; $i < $subtun_count; $i++) {
            if ( $i == $last_sock_index ) {
                next;
            }

            my $sock_hash = dccp_get_tx_infos($i);
            # $srtt is in microseconds (10^-6), $delta is in seconds
            # therefore * 1_000_000 to make them comparable
            if ( $sock_hash->{srtt} + ($delta * 1_000_000) >= $last_sock_hash->{srtt} ) {
                push(@applicable_subtun_hashes, $sock_hash);
            }
        }

        my $packet_size = bytes::length($_[0]);
        my $opti_sock_id = select_adaptively(\@applicable_subtun_hashes, $packet_size);

        # since $value_array is a ref to the array, the following
        # also updates the real array in %flow_table
        $value_array->[0] = $opti_sock_id;
        $value_array->[1] = time();
        $ALGOLOG->NOTICE("send_scheduler_afmt_fl(): continuing existing flow $flow_id , using sock id: $opti_sock_id, packet size: $packet_size");
        $poe_kernel->call( $subtun_sessions[$opti_sock_id], "on_data_to_send", $_[0], $packet_size );
        return;
    } else { # packet starts a new flow
        # prepare the array of available subtun hashes
        # with the hashes containing all the stats necesarry for the algo to decide
        my @applicable_subtun_hashes;
        for (my $i = 0; $i < $subtun_count; $i++)
        {
            my $sock_hash = dccp_get_tx_infos($i);
            push(@applicable_subtun_hashes, $sock_hash);
        }

        my $packet_size = bytes::length($_[0]);
        my $opti_sock_id = select_adaptively(\@applicable_subtun_hashes, $packet_size);

        # we create a new value_array and put a ref to it into the %flow_table
        $value_array = [$opti_sock_id, time()];
        $flow_table{$flow_id} = $value_array;

        $ALGOLOG->NOTICE("send_sched_afmt(): Started new flow send through sock id: $opti_sock_id , packet size: $packet_size\n");
        $poe_kernel->call( $subtun_sessions[$opti_sock_id], "on_data_to_send", $_[0], $packet_size );

        return;
    }
}

# SRTT min as used by multipath TCP
# Here a "free socket" is a socket with room in its cwnd to send packets
# 1. from all the free sockets choose the one with lowest srtt and send there
# 2. if no sockets are free, wait
#
# Here we implement this the following way
#   1. this function gets called when there is a new packet p to send (stored in $_[0])
#   2. We check all subtun sockets for their tx_info (srtt, fill, etc.)
#   3. We put these with 0 socket fill into an array
#   4. We iterate through that array, picking the socket s with lowest srtt
#   5. We use s to send p
sub send_scheduler_srtt_min
{
    # we only get 1 parameter: a network packet ~1500 bytes
    # we're not using shift but $_[0] (see below, in the $kernel->call(...))
    # to avoid copying the full 1500 bytes
    my $packet_size = bytes::length($_[0]);
    my @free_sockets;

    for (my $i = 0; $i < $subtun_count; $i++)
    {
        my $sock_hash = dccp_get_tx_infos($i);
        if ( $sock_hash->{sock_fill} <= 0) {
            push(@free_sockets, $sock_hash);
        }
    }

    my $opti_sock_id;
    my $minimal_srtt = 1_000_000_000; # in us (10^-6)
    for my $sock_hash (@free_sockets) {

        if ( $sock_hash->{srtt} < $minimal_srtt) {
            $minimal_srtt = $sock_hash->{srtt};
            $opti_sock_id = $sock_hash->{socket_id};
        }

    }

    $poe_kernel->call( $subtun_sessions[$opti_sock_id], "on_data_to_send", $_[0], $packet_size );
}

sub tun_read {
    my $buf;
    while(sysread($_[HEAP]->{tun_device}, $buf , TUN_MAX_FRAME ))
    {
        # $packet_scheduler is a reference to a function
        # & dereferences it for calling see man perlref for details, same as with @$ for array references
        &$packet_scheduler($buf);
    }
}

sub get_sock_sendbuffer_fill
{
    my $sock = shift;

    # Get sock send buffer fill
    my $ioctl_binary_return_buffer = "";
    my $sock_sendbuffer_fill;
    my $retval = ioctl($sock, SIOCOUTQ, $ioctl_binary_return_buffer); 
    if (!defined($retval)) {
        $ALGOLOG->ERR($!);
    } else {
        # say(unpack("i", $ioctl_binary_return_buffer));
        $sock_sendbuffer_fill = unpack("i", $ioctl_binary_return_buffer);
    }
    $ALGOLOG->DEBUG("get sendbuffer fill(): buffer fill: $sock_sendbuffer_fill");
    return $sock_sendbuffer_fill;
}

sub send_scheduler_rr
{
    # we only get 1 parameter: a network packet ~1500 bytes
    # we're not using shift but $_[0] (see below, in the $kernel->call(...))
    # to avoid copying the full 1500 bytes

    # State is same as static for local variables in C
    # Value of variables is persistent between function calls, because stored on the heap
    state $current_subtun_id = 0;
    my $cur_subtun = $subtun_sockets[$current_subtun_id];
    my $subtun_count = @subtun_sessions;

    if ( $subtun_count == 0) {
        say("  send_scheduler_rr called with no subtunnels???");
        return;
    }

    # if ( $loglevel_algo eq 'INFO'
    #      || $loglevel_algo eq 'DEBUG')
    # {
    #     my ($send_rate, $calc_rate, $srtt, $sock_sendbuffer_fill) =
    #         dccp_get_tx_infos($cur_subtun);

    #     $ALGOLOG->INFO("Just scheduled 1 payload package through subtunnel $current_subtun_id , got $subtun_count subtunnels\n" .
    #         "Packet size:          " . bytes::length($_[0]) . "\n" .
    #         "Send rate:            " . $send_rate . "\n" .
    #         "Sock sendbuffer fill: " . $sock_sendbuffer_fill . "\n" .
    #         "SRTT:                 " . $srtt);
    # }

    $poe_kernel->call( $subtun_sessions[$current_subtun_id], "on_data_to_send", $_[0] );

    $current_subtun_id = ($current_subtun_id+1) % $subtun_count;
    return;
}

# Receives from a subtunnel and puts into tun/tap device
sub tun_write
{
    my ( $heap, $buf ) = @_[ HEAP, ARG0 ];

    # write data of $buf into the tun-device
    syswrite( $heap->{tun_device}, $buf );

}


sub create_tun_interface
{
    my $heap = shift;

    # true if tun interface, false if tap
    my $tun_or_tap =
        (      ( $config->{local}->{ip} =~ /^[\d\.]+$/ )  # rough check if valid ip
               && ( $config->{local}->{tun_or_tap} !~ /tap/ ) ) ? 1 : 0;

    $heap->{tun_device} = new IO::File( TUNNEL_DEVICE, 'r+' )
        or die "Can't open " . TUNNEL_DEVICE . ": $!";

    my $if_init_request = pack( STRUCT_IFREQ,
                         $tun_or_tap ? 'tun%d' : 'tap%d',
                         $tun_or_tap ? IFF_TUN : IFF_TAP );

    ioctl($heap->{tun_device}, TUNSETIFF, $if_init_request)
        or die "Can't ioctl() tunnel: $!";

    # When called in scalar context, unpack returns only the first member of the unpacked data
    # which is conveniently here, the exact name the tun interface got.
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
    # if no IP+subnet found in conf file, do something obscure with bridge interfaces
        system( "ifconfig " . $heap->{tun_if_name} . " up" );
        system( "brctl", "addif", $config->{local}->{ip}, $heap->{tun_if_name} );
    }

    # # Set PMTU Clamping
    # if (( $config->{local}->{mtu} )) {
    #     system( "iptables -A FORWARD -o "
    #         . $heap->{tun_if_name}
    #         . " -p tcp -m tcp --tcp-flags SYN,RST SYN -m tcpmss --mss "
    #         . ( $config->{local}->{mtu} - 40 )
    #         . ":65495 -j TCPMSS --clamp-mss-to-pmtu" );
    # }

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




sub setup_dccp_client
{
    my $subtunname = shift;
    my $new_subtunnel  = $config->{subtunnels}->{$subtunname};

    POE::Session->create(
    inline_states => {
        _start => sub {
        # Instantiate the socket factory
        $_[HEAP]{socket_factory} = POE::Wheel::SocketFactory->new(
            RemoteAddress  => $new_subtunnel->{dstip},
            RemotePort     => 12345,
            SuccessEvent   => "on_connection_established",
            FailureEvent   => "on_connection_error",
            SocketDomain   => PF_INET,
            SocketType     => SOCK_DCCP,
            SocketProtocol => IPPROTO_DCCP,
        );
        },
        on_connection_established => sub {
            $_[HEAP]{subtun_sock} = $_[ARG0];
            # Put this sessions id in our global array
            # And the corresponding subtun socket in a second array, at same index number
            push(@subtun_sessions, $_[SESSION]->ID());
            push(@subtun_sockets, $_[ARG0]);
            $poe_kernel->select_read($_[HEAP]{subtun_sock}, "on_input");
            $CONLOG->NOTICE(colored("DCCP Client: ", 'bold green')
                . "Succesfully connected one subtunnel");
            # say(Dumper($_[HEAP]{subtun_sock}));
        },
        on_input        => \&dccp_subtun_minimal_recv,
        on_data_to_send => \&dccp_subtun_minimal_send,
        on_connection_error => sub {
            my ($operation, $errnum, $errstr) = @_[ARG0, ARG1, ARG2];
            warn("Client $operation error $errnum: $errstr\n");
            delete $_[HEAP]{socket_factory};
            delete $_[HEAP]{subtun_sock};
        },
    }
    );

}


sub dccp_subtun_minimal_recv
{
    my $curinput = undef;

    my $bytes_read = $_[HEAP]{subtun_sock}->sysread($curinput, 1600);
    $TXRXLOG->DEBUG("Recieved one DCCP packet. $bytes_read bytes");

    $_[KERNEL]->call($tuntap_session => "put_into_tun_device", $curinput);
}

sub dccp_subtun_minimal_send
{
    my $payload = $_[ARG0];
    my $packet_size = $_[ARG1];

    # If loglevel is debug: ask dccp socket for max packet size and print it
    if ( $TXRXLOG->level() eq 'DEBUG' ) {
        my $packed = getsockopt($_[HEAP]{subtun_sock}, SOL_DCCP, DCCP_SOCKOPT_GET_CUR_MPS);
        my $max_packet_size = unpack("I", $packed);
        say("accepted subtun max packet size: $max_packet_size");
    }

    my $actually_sent_bytes =  $_[HEAP]->{subtun_sock}->syswrite($payload);
    $TXRXLOG->ERR("dccp_subtun_minimal_send(): socket error: errno: $!") if (!defined($actually_sent_bytes));
#    $TXRXLOG->DEBUG("Sent payload through DCCP subtunnel $actually_sent_bytes of $packet_size bytes");
}

sub dccp_server_new_client {
    my $client_socket = $_[ARG0];

    ## Create a new session for every new dccp subtunnel socket
    POE::Session->create(
        inline_states => {
            _start    => sub {
                $_[HEAP]{subtun_sock} = $_[ARG0];
                # Put this session's id in our global array
                # And the corresponding subtun socket in a second array, at same index number
                push(@subtun_sessions, $_[SESSION]->ID());
                push(@subtun_sockets, $_[ARG0]);
                $CONLOG->WARN(colored("DCCP Server: ", 'bold green')
                       . "Succesfully accepted one subtunnel");
                my $packed = getsockopt($_[HEAP]{subtun_sock}, SOL_DCCP, DCCP_SOCKOPT_GET_CUR_MPS);
                my $max_packet_size = unpack("I", $packed);
                say("accepted subtun max packet size: $max_packet_size");
                # $_[HEAP]{subtun_sock}->setsockopt(SOL_SOCKET, SO_SNDBUF, 2048);

                $poe_kernel->select_read($_[HEAP]{subtun_sock}, "on_data_received");
            },
            on_data_received => \&dccp_subtun_minimal_recv,
            on_data_to_send => \&dccp_subtun_minimal_send,
        },
        args => [$client_socket],
    );
}

sub evaluate_if_server
{
    my $server_sockets = 0;
    my $subtun_count = 0;
#    say(Dumper($config));
    for my $subtun_name ( keys(%{$config->{subtunnels}}) ) {

        my $cur_subtun = $config->{subtunnels}->{$subtun_name};
        $subtun_count++;

        if ( !defined($cur_subtun->{dstip})
                 && !defined($cur_subtun->{dstport}))
        {
            $server_sockets++;
        }
    }

    if ( $server_sockets == $subtun_count ) {
        $dccp_Texit = 1;
        say(colored("I'm T_exit", "bold green"));
    } elsif ($server_sockets == 0) {
        $dccp_Texit = 0;
        say(colored("I'm T_entry", "bold yellow"));
    } else {
        die("I am server for some subtunnels and client for others, why????");
    }
}

####### Section 1 END: Function Definitions #############

parse_cli_args();
parse_conf_file();
evaluate_if_server();
init_loggers();

if ( $sched_algo eq 'afmt_fl') {
    $packet_scheduler = \&send_scheduler_afmt_fl;
} elsif ( $sched_algo eq 'rr') {
    $packet_scheduler = \&send_scheduler_rr;
} elsif ( $sched_algo eq 'srtt_min') {
    $packet_scheduler = \&send_scheduler_srtt_min;
} else {
    die("Invoked with unknown scheduler name");
}

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

if ( !$dccp_Texit) {
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
        got_packet_from_tun_device => \&tun_read,
        put_into_tun_device => \&tun_write,
    }
);

set_via_tunnel_routes(1);

$poe_kernel->run();
