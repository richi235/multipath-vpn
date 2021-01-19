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
use Scalar::Util qw(looks_like_number);

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
my $tuntap_session = undef;
my @subtun_sessions = ();  # contains session IDs
my @subtun_sockets  = ();  # contains socket file handles
my @recently_used = ();    # true if used in th last 100ms used for keepalives, indexed by sock_ids
my $packet_scheduler;      # contains a function

$| = 1;                    # disable terminal output buffering
my $config   = {};   # complex hash, filled by conf reader
my $conf_file_name = "/etc/multivpn.cfg";
my $ccid_to_use = 2;
my $start_time;

# ## Log::Fast Loglevels ## One out of:
# ERR
# WARN
# NOTICE
# INFO
# DEBUG
my $loglevel_txrx = 'WARN';
my $loglevel_algo = 'WARN';
my $loglevel_flowids = 'WARN';
my $loglevel_connect = 'NOTICE';
my $loglevel_scilog  = 'WARN';
my $own_header = 0;

my $sched_algo = "afmt_fl";

my $help = 0;

# The Log::Fast (component wise) loggers
my $TXRXLOG;
my $ALGOLOG;
my $CONLOG;
my $FLOWLOG;
my $SCILOG;

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
               'lflow=s'      => \$loglevel_flowids,
               'ltx=s'        => \$loglevel_txrx,
               'lsci=s'       => \$loglevel_scilog,
               'lalgo=s'      => \$loglevel_algo,
               'sched=s'      => \$sched_algo,
               'ccid=i'       => \$ccid_to_use,
               'h|help'       => \$help,
               'hdr'          => \$own_header);

    if ( $help ) {
        say("This is the unofroest Multipath Tunneling prototype, for scientific testing. Science!
It supports the following cli params:
         'c|conf=s'     => \$conf_file_name, # /etc/multivpn.cfg is default
         'ccid=i'       => \$ccid_to_use,

         'sched=s'      => \$sched_algo, # 'rr' or 'srtt_min_busy_wait' or 'afmt_fl'(default)
                           # or 'otias_sock_drop' or 'afmt_noqueue_(drop|busy_wait)'
                           # or 'llfmt_noqueue_busy_wait'
         'h|help'       => \$help
         'hdr'          => \$own_header

  ## Logging: (Levels: ERR | WARN | NOTICE | INFO | DEBUG)
         'lcon=s'       => \$loglevel_connect # default: NOTICE
         'ltx=s'        => \$loglevel_txrx, # default: WARN
         'lflow=s'      => \$loglevel_flowids, # default: WARN
         'lsci=s'       => \$loglevel_scilog,  # default: NOTICE
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
        # TODO: Hier noch switching zu den anderen algos (srtt_min und otias) einbauen
        # evtl. mit array aller algos und einem next + cycling
        # evtl. auch hash aus name/string und funktionspointer
    } else {
        die("WTF, should toggle sched algo but there's no sched algo I know of configured\n");
    }
}

sub init_loggers
{
    open(my $scilog_file_fd, ">", "/tmp/time_inflight_cwnd_srtt.tsv")
        or croak("failed to open logfile for scilog");

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
        level           => $loglevel_connect,
        type            => 'fh',
        fh              => \*STDOUT,
    });

    $FLOWLOG = Log::Fast->new({
        level           => $loglevel_flowids,
        type            => 'fh',
        fh              => \*STDOUT,
    });

    $SCILOG = Log::Fast->new({
        level           => $loglevel_scilog,
        type            => 'fh',
        fh              => \*$scilog_file_fd,
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
    $FLOWLOG->INFO("get_flow_id(): Packet size: $packet_size");
    # using $_[0] because with shift we would copy the whole packet, and that would be bad for performance
    # This copies the packet and removes the 4 byte TunTap header
    my $raw_ip_packet = bytes::substr($_[0], 4);

    # parse the packet
    my $ip_obj = NetPacket::IP->decode($raw_ip_packet);

    $FLOWLOG->DEBUG(Dumper($ip_obj));
    $FLOWLOG->DEBUG(IP_VERSION_IPv4); #dump the constant

    # Check if this is an IPv4 packet at all
    # if not return an error, we can not work with this here
    if ( $ip_obj->{ver} != IP_VERSION_IPv4 ) {
        $FLOWLOG->WARN("INFO: get_flow_id(): No IPv4 packet");
        return -2;
    }
    $FLOWLOG->INFO("get_flow_id(): IP Parsing succesfull: $ip_obj->{src_ip} : $ip_obj->{dest_ip} : $ip_obj->{proto}" );

    my ($src_port, $dest_port);

    if ( $ip_obj->{proto} == IP_PROTO_TCP ) {
        my $tcp_obj = NetPacket::TCP->decode($ip_obj->{data});
        $FLOWLOG->INFO("$tcp_obj->{src_port} : $tcp_obj->{dest_port}");
        $src_port  = $tcp_obj->{src_port};
        $dest_port = $tcp_obj->{dest_port};
    } elsif ($ip_obj->{proto} == IP_PROTO_UDP)
    {
        my $udp_obj = NetPacket::UDP->decode($ip_obj->{data});
        $FLOWLOG->INFO("$udp_obj->{dest_port} : $udp_obj->{src_port}");
        $src_port  = $udp_obj->{src_port};
        $dest_port = $udp_obj->{dest_port};
    } else {
        $FLOWLOG->ERR("Error: unparsable packet");
        return -2;
    }

    my $tupel_string = "$ip_obj->{src_ip}:$src_port --> $ip_obj->{dest_ip}:$dest_port";

    my $flow_id;
    if (defined( $flow_id = $tupel_to_id{$tupel_string})) {
        # yas, we know that flow, return its id
        $FLOWLOG->INFO("Found Flow id: $flow_id for $tupel_string");
        return $flow_id;
    } else {
        # create a new entry, return newly assigned id
        $max_flow_id++;
        $tupel_to_id{$tupel_string} = $max_flow_id;
        $FLOWLOG->INFO("Created new Flow id: $max_flow_id for $tupel_string");
        return $max_flow_id;
    }
}
# takes:  1. ref to applicable subtunnels array , 2. size of the packet to send
# returns: socket_id (int) of the chosen socket
sub afmt_fl_adaptivity
{
    my @applicable_subtun_hashes = @{$_[0]};
    my $packet_size = $_[1];

    my $opti_sock_id;
    my $min_weighted_fill = 1_000_000_000_000;

    if ( 0 == @applicable_subtun_hashes ) {
        $ALGOLOG->ERR("Error: afmt_fl_adaptivity() called with empty subtun_hashes array");
        exit(-1);
    }

    if ( 1 == @applicable_subtun_hashes) {
        # if only one subtunnel is applicable (no overtaking/reordering produced)
        # just return that
        $ALGOLOG->NOTICE("afmt_fl_adaptivity(): called with only 1 arg");
        return $applicable_subtun_hashes[0]->{sock_id};
    }

    for my $subtun_hash (@applicable_subtun_hashes) {
        my $weighted_fill =
            ( ( ($subtun_hash->{sock_fill}*$subtun_hash->{sock_fill}) + $packet_size) /
                  ($subtun_hash->{send_rate} || 1) )
            * $subtun_hash->{srtt};
#        say(colored($weighted_fill, "bold red"));
        $ALGOLOG->NOTICE("afmt_fl_adaptivity(): sock_id: $subtun_hash->{sock_id}"
                           . " | srtt:" . $subtun_hash->{srtt}/1000 . "ms"
                           . " | send_rate:" . ($subtun_hash->{send_rate}) . " (B/s)"
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
            srtt        => $srtt >> 1,  # smoothed RTT estimate
            send_rate   => $cwnd,
            sock_fill   => $buffer_fill,
            in_flight   => $pipe,
        };
    } else {
        die("dccp_get_tx_infos(): unknown ccid used\n");
    }

    $ALGOLOG->DEBUG(
        "send_rate/cwnd: " . ($sock_hash->{send_rate}) . " (B/s)"  #  / 64  / 1024
                    # . " | peer recv_rate:" . ($recv_rate >> 16) . "kB/s"
                    . " | SRTT: " . $sock_hash->{srtt} . "μs or ms*8"
                    . " | sock_fill: " . $sock_hash->{sock_fill}
                    # . " | ccwnd: " . (($send_rate >> 6)*($srtt/1_000_000))/1_000 . "kB"
                );
    $SCILOG->NOTICE("%f    $sock_hash->{sock_id}    $sock_hash->{in_flight}    $sock_hash->{send_rate}    $sock_hash->{srtt}",
                    sub {return time() - $start_time; # rel_time
                     }) if ($ccid_to_use == 2);
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
    sysread($_[HEAP]->{tun_device}, my $packet , TUN_MAX_FRAME );

    # When no subtunnels available, don't work and return
    # Maybe we are still in warmup phase
    if ( $subtun_count == 0) {
        $ALGOLOG->WARN("send_scheduler_afmt_fl called with no subtunnels??? not sending, dropping");
        return -1;
    }

    # uses our own flow tracking system
    my $flow_id = get_flow_id($packet);

    # flow id -2 means it was no proper IPv4 packet, print error message and return
    # We don't forward non-ipv4 traffic currently
    if ( $flow_id == -2) {
        $ALGOLOG->WARN("WARNING: send_scheduler_afmt_fl(): payload ist no IPv4 packet, dropping it\n");
        return;
        # just returning without sending the packet is equivalent to droppning it
    }

    $ALGOLOG->DEBUG("\n%f  send_scheduler_afmt_fl() called with $subtun_count sockets, succesfully got flow id: $flow_id", sub { return time() - $start_time; });
    my $packet_size = bytes::length($packet);

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

        my $opti_sock_id = afmt_fl_adaptivity(\@applicable_subtun_hashes, $packet_size);

        # since $value_array is a ref to the array, the following
        # also updates the real array in %flow_table
        $value_array->[0] = $opti_sock_id;
        $value_array->[1] = time();
        $ALGOLOG->NOTICE("%f   send_scheduler_afmt_fl(): continuing existing flow $flow_id , using sock id: $opti_sock_id, packet size: $packet_size", sub { return time() - $start_time; });
        $poe_kernel->call( $subtun_sessions[$opti_sock_id], "on_data_to_send", $packet );
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

        my $opti_sock_id = afmt_fl_adaptivity(\@applicable_subtun_hashes, $packet_size);

        # we create a new value_array and put a ref to it into the %flow_table
        $value_array = [$opti_sock_id, time()];
        $flow_table{$flow_id} = $value_array;

        $ALGOLOG->NOTICE("send_sched_afmt(): Started new flow send through sock id: $opti_sock_id , packet size: $packet_size\n");
        $poe_kernel->call( $subtun_sessions[$opti_sock_id], "on_data_to_send", $packet );
        return;
    }
}

# returns: ref to array of the socket hashes of the free sockets
sub get_free_sockets
{
    my $subtun_count = @subtun_sockets;
    my @free_sockets = ();

    if ( $subtun_count == 0) {
        $ALGOLOG->WARN("get_free_sockets: called with 0 subtunnels existing");
        return \@free_sockets;
    }

    for (my $i = 0; $i < $subtun_count; $i++)
    {
        my $sock_hash = dccp_get_tx_infos($i);
        my $free_slots = $sock_hash->{send_rate} - $sock_hash->{in_flight};

        if ( $free_slots > 0) {
            push(@free_sockets, $sock_hash);
        }
        $ALGOLOG->INFO("%f   get_free_sockets: sock_id: $i | cwnd: $sock_hash->{send_rate} | free slots: $free_slots" . " | SRTT: $sock_hash->{srtt}", sub { return time() - $start_time; });
    }

    my $free_sock_count = @free_sockets;
    $ALGOLOG->INFO("SRTT: subtun_count: $subtun_count | free_sockets: $free_sock_count");

    return \@free_sockets;
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
    my $opti_sock_id = -1;
    my $minimal_srtt = 1_000_000_000; # in us (10^-6)

    my $free_sockets_ref = get_free_sockets();

    for my $sock_hash (@$free_sockets_ref) {

        if ( $sock_hash->{srtt} < $minimal_srtt) {
            $minimal_srtt = $sock_hash->{srtt};
            $opti_sock_id = $sock_hash->{sock_id};
        }
    }

    if ( $opti_sock_id == -1) { # found no opti sock
        $ALGOLOG->NOTICE("SRTT: Found no usable socket/subtun");
        return -1;
    } else { # found opti sock: send packet
        $ALGOLOG->NOTICE("SRTT_min: chosen socket: $opti_sock_id | with SRTT: $minimal_srtt");
        sysread($_[HEAP]->{tun_device}, my $packet , TUN_MAX_FRAME );
        $poe_kernel->call( $subtun_sessions[$opti_sock_id], "on_data_to_send", $packet );
        return 1;
    }
}

sub send_scheduler_otias
{
    my $subtun_count = @subtun_sockets;
    my $minimal_delay = 1_000_000;
    my $opti_sock_id = -1;

    if ( $subtun_count == 0) {
        $ALGOLOG->WARN("%f  OTIAS: Called with 0 subtuns available"
                           , sub { return time() - $start_time; } );
        return -1;
    }

    if ( $subtun_count == 1 ) {
        $opti_sock_id = 0; # if there's only it's 0 @subtun_sockets starts from 0
        $ALGOLOG->INFO("OTIAS: called with only 1 subtun, using it directly");
        goto success;
    }

    # $subtun_count is >= 2
    # main algo starts here all error cases and potential edge cases handled
    for (my $i = 0; $i < $subtun_count; $i++)
    {
        my $sock_hash = dccp_get_tx_infos($i);
        my $sendable_packet_count = $sock_hash->{send_rate} - $sock_hash->{in_flight};

        # wie mache ich das hier jetzt mit #packets_not_yet_sent i.e. sock fill?
        # umrechnen?
        # Entscheidung: hier jetzt erstmal mit näherung rechnen also socket_fill / packet size
        my $packets_not_sent = POSIX::ceil($sock_hash->{sock_fill} / 1400);
        # Here we take 1400 as an average packet size and round up so 3.44 becomes 4
        # because that's how many skbs are stored in the queue anyway

        my $number_of_RTTs_to_wait =
            POSIX::floor(  ($packets_not_sent - $sendable_packet_count)
                                       / $sock_hash->{send_rate});
        my $estimated_delay = ($number_of_RTTs_to_wait + 0.5) * $sock_hash->{srtt};

        $ALGOLOG->INFO("sock id: $i | free slots: $sendable_packet_count | not sent: $packets_not_sent"
                         . "RTTs_to_wait: $number_of_RTTs_to_wait | estimated delay (ms): $estimated_delay");
        if ($estimated_delay < $minimal_delay) {
            $minimal_delay = $estimated_delay;
            $opti_sock_id = $i;
        }
    }

    if ( $opti_sock_id == -1) {
        return -1;
        $ALGOLOG->WARN("%f  OTIAS: Warning: found no optimal path"
                           , sub {return time() - $start_time; } );
    }

 success:
    $ALGOLOG->NOTICE("Chosen socket: $opti_sock_id | with delay: $minimal_delay");
    sysread($_[HEAP]->{tun_device}, my $packet , TUN_MAX_FRAME );
    $poe_kernel->call( $subtun_sessions[$opti_sock_id], "on_data_to_send", $packet );
}


### How we handle full socket send queues
#
# i.e. we get new packet from packet from tun fd, but can not send it.
# We operate on non-blocking sockets. So a full socket is technically not blocking
# but just returning EAGAIN.
# Ways to find out if socket is blocking: get_tx_info() and looking at
# cwnd, pipe, und send_buffer_fill. When cwnd is full, there stack up unsent packets in
# the send buffer (which can and are not instantly sent), that buffer is limited to 5 packets.
#
# Depinding on the algo:
#
# 1. srtt_min (busy_wait)
# Here we do not want to build up any packet queue in the send buffer, only in the
# queue of the tun fd. And we can look up if any socket is ready without having to dequeue
# a packet. There we first run the algo and if it returns a good subtunnel (i.e. not -1)
# we dequeue a packet with sysread and send it through that subtunnel.
# When the aglo returns -1 we have the possibility of busy waiting or switching to
# "socket based select" for now I chose busy waiting
#
# 2. OTIAS sock_drop
# OTIAS actively contains to build up queues on the sockets. Therefore we first have to
# enlarge the queue size from 5 to 10 (or 15). But what does OTIAS do when a/the send buffers
# of the subordinate sockets are full? I couldn't find anything in the original paper on that
# (Out-of-order Transmission for In-order Arrival Scheduling for Multipath TCP
# , Fan Yang, Qi Wang). So I assume it just pushes it in there anyway and risks tail drop
# and also implement it this way here. i.e. just always send on the path the algo says
# is "ideal"
#
# 3. AFMT noqueue sock_drop
# We need to take the packet out of the tun fd to do our scheduling decision. If
# no good subtunnel to send:
#
# Possibility 1: Just put it in the best socket there is, accept tail droping
#
# Possibility 2: Keep the one packet, switch mode to "socket select". Activate aglo
# everytime a socket triggers, first select stored packet. if again not sendable just do nothing
# select will do busy waiting this time, trigger again and again, until it's finally sendable
# some way. Then it will pick next paket from tun interface. If tun interface is ever empty
# switch back to "tun select mode"
#
# Possibility 3: Keep packet, and do busy waiting until good socket available again
# i.e. everytime triggerd we check if there is a "leftover packet" and process that if it
# exists
#
# 4. AFMT noqueue busy_wait
#
# 5. AFMT_FL (old)
#
# For now, for easyness I go with possibilty 1
#
# So there are to different dimensions to the blocking problem:
# 1. push packet in anyway or not(i.e. wait or sth else)
# 2. busy wait or switch blocking mode (only relevant if you chose not at 1.)
sub tun_read
{
    # $packet_scheduler is a reference to a function
    # & dereferences it for calling see man perlref for details, similar to @$ for array refs
    &$packet_scheduler();

    # TODO: $packet size aus verschiedenen funktionen entfernen (weil eh egal bei dccp eig.)
}

sub get_sock_sendbuffer_fill
{
    my $sock = shift;

    # Get sock send buffer fill
    my $ioctl_binary_return_buffer = "";
    my $sock_sendbuffer_fill;
    my $retval = ioctl($sock, SIOCOUTQ, $ioctl_binary_return_buffer);
    if (!defined($retval)) {
        $ALGOLOG->ERR("%f  $!", sub { return time() - $start_time; } );
    } else {
        # say(unpack("i", $ioctl_binary_return_buffer));
        $sock_sendbuffer_fill = unpack("i", $ioctl_binary_return_buffer);
    }
    $ALGOLOG->DEBUG("get sendbuffer fill(): buffer fill: $sock_sendbuffer_fill");
    return $sock_sendbuffer_fill;
}

sub send_scheduler_afmt_noqueue_drop
{
    sysread($_[HEAP]->{tun_device}, my $packet , TUN_MAX_FRAME );
    my $opti_sock_id = afmt_noqueue_base($packet, \&afmt_base_adaptivity);

    if ( $opti_sock_id < 0 ) { # found no usable sock: drop packet
        $ALGOLOG->NOTICE("%f  AFMT_NOQUEUE_DROP: had to drop packet", sub { return time() - $start_time; });
        return -1;
    } else { # found opti sock: send packet
        $ALGOLOG->NOTICE("%f  AFMT_NOQUEUE_DROP: sent a packet via $opti_sock_id", sub { return time() - $start_time; });
        $poe_kernel->call( $subtun_sessions[$opti_sock_id], "on_data_to_send", $packet );
    }
}

sub send_scheduler_afmt_noqueue_busy_wait
{
    state $packet = -2; # -2 symbolizes empty
    if ( looks_like_number($packet)
         && $packet == -2) { # if we have no "kept unsent" packet
        # get a new from tun interface
        sysread($_[HEAP]->{tun_device}, $packet , TUN_MAX_FRAME );
    }
    # looks_like_number() is actually the most performant way to check this
    # because it asks internally tnhe perl interpreter, although its name  does not sound like it^^

    my $opti_sock_id = afmt_noqueue_base($packet, \&afmt_base_adaptivity);

    if ($opti_sock_id == -3) {
        # $packet was no proper IPv4 packet
        $packet = -2; # reset $packet
        return 1; # positive because technically one packet was succesfully processed
    } elsif ( $opti_sock_id < 0 ) { # found no usable sock
        $ALGOLOG->NOTICE("AFMT_NOQUEUE_busy_wait: couldn't send, return busy loop");
        # $packet is not reset i.e. stays the same because it's a state variable
        return -1;
    } else {                    # found opti sock: send packet
        $ALGOLOG->NOTICE("%f  AFMT_NOQUEUE_busy_wait: sent a packet via $opti_sock_id", sub { return time() - $start_time; });
        $poe_kernel->call( $subtun_sessions[$opti_sock_id], "on_data_to_send", $packet );
        $packet = -2; # reset $packet
        return 1;
    }
}

sub send_scheduler_llfmt_noqueue_busy_wait
{
    state $packet = -2; # -2 symbolizes empty
    if ( looks_like_number($packet)
         && $packet == -2) { # if we have no "kept unsent" packet
        # get a new from tun interface
        sysread($_[HEAP]->{tun_device}, $packet , TUN_MAX_FRAME );
    }
    # looks_like_number() is actually the most performant way to check this
    # because it asks internally tnhe perl interpreter, although its name  does not sound like it^^

    my $opti_sock_id = afmt_noqueue_base($packet, \&llfmt_ll_selector);

    if ($opti_sock_id == -3) {
        # $packet was no proper IPv4 packet
        $packet = -2; # reset $packet
        return 1; # positive because technically one packet was succesfully processed
    } elsif ( $opti_sock_id < 0 ) { # found no usable sock
        $ALGOLOG->NOTICE("%f  AFMT_NOQUEUE_busy_wait: couldn't send, return busy loop", sub { return time() - $start_time; });
        # $packet is not reset i.e. stays the same because it's a state variable
        return -1;
    } else {                    # found opti sock: send packet
        $ALGOLOG->NOTICE("%f  AFMT_NOQUEUE_busy_wait: sent a packet via $opti_sock_id", sub { return time() - $start_time; });
        $poe_kernel->call( $subtun_sessions[$opti_sock_id], "on_data_to_send", $packet );
        $packet = -2; # reset $packet
        return 1;
    }
}

#    1. erst kucken welche socks available  (loop)
#       - also get_tx_info() callen
#       - und available == free_slots == cwnd - in_flight > 0
#    2. dann von denen kucken wo nicht überholen  (loop)
#       - da evtl. code von afmt_fl kopieren, evlt. in eigene funktion packen
#    3. dann von denen den mit most free slots nehmen (loop)
#      - oder free_slots / srtt
#      - hatt da iwo notitzen zu
#
#    und halt überall noch logging
sub afmt_noqueue_base
{
    my $adaptivity_function = $_[1];
    my $subtun_count = @subtun_sessions;
    # When no subtunnels available, don't work and return
    if ( $subtun_count == 0) {
        $ALGOLOG->WARN("%f  afmt_base called with no subtunnels. not sending, dropping",
                   sub { return time() - $start_time; });
        return -1;
    }

    # 1. get available socks (comparable to srtt_min, in eigene funktion packen?)
    my $free_sockets_ref = get_free_sockets();

    if ( @$free_sockets_ref == 0) {
        $ALGOLOG->NOTICE("%f  afmt_noqueue_base: Aborting: no free socks", sub { return time() - $start_time; });
        return -2;
    }

    # 2. make sure anti reordering (no overtaking):
    # uses our own flow tracking system
    my $flow_id = get_flow_id($_[0]);

    if ( $flow_id == -2) {
        # flow id -2 means it was no proper IPv4 packet, print error message and return
        # We don't forward non-ipv4 traffic currently
        $ALGOLOG->WARN("WARNING: send_scheduler_afmt_noqueue_base(): payload ist no IPv4 packet, dropping it\n");
        return -3;
    }
    # TODO: flow id buffern?
    # TODO: entscheiden: get flow id vorziehen?

    # If packet is part of a known flow:
    if ( defined (my $value_array = $flow_table{$flow_id})) {
        my $last_sock_index = $value_array->[0]; # the index to the global subtunnel and sock arrays

        # the time stamp of when the last packet of this flow was send
        my $last_send_time = $value_array->[1];

        my $now = time();
        my $delta = $now - $last_send_time; # delta in seconds (float with 10^-6 accuracy (microseconds))

        my $last_sock_hash = dccp_get_tx_infos($last_sock_index); # could be taken from a cache

        my @applicable_subtun_hashes;
        for my $sock_hash (@$free_sockets_ref) {
            # $srtt is in microseconds (10^-6), $delta is in seconds
            # therefore * 1_000_000 to make them comparable
            if ( $sock_hash->{srtt} + ($delta * 1_000_000) >= $last_sock_hash->{srtt} ) {
                push(@applicable_subtun_hashes, $sock_hash);
            }
        }

        if ( 0 == @applicable_subtun_hashes) {
            $ALGOLOG->NOTICE("%f  afmt_base: got >= 1 free sockets, but all would overtake, not sending", sub { return time() - $start_time; });
            return -4;
        }

        my $opti_sock_id = &{$adaptivity_function}(\@applicable_subtun_hashes);
        # since $value_array is a ref to the array, the following
        # also updates the real array in %flow_table
        $value_array->[0] = $opti_sock_id;
        $value_array->[1] = time();
        $ALGOLOG->NOTICE("%f  send_scheduler_afmt_fl(): continuing existing flow $flow_id , using sock id: $opti_sock_id", sub { return time() - $start_time; });
        return $opti_sock_id;

    } else { # packet starts a new flow
        my $opti_sock_id = &{$adaptivity_function}($free_sockets_ref);

        # we create a new value_array and put a ref to it into the %flow_table
        $value_array = [$opti_sock_id, time()];
        $flow_table{$flow_id} = $value_array;

        $ALGOLOG->NOTICE("%f  send_sched_afmt(): Started new flow send through sock id: $opti_sock_id", sub { return time() - $start_time; });
        return $opti_sock_id;
    }
}

# selects the path with lowest srtt, it's that simple
# pre conditions we can be sure of: @$sock_hashes_ref is not empty
sub llfmt_ll_selector
{
    my $sock_hashes_ref = shift;
    my $minimal_srtt = 1_000_000_000; # in us (10^-6)
    my $opti_sock_id = -1;

    if ( 1 == @$sock_hashes_ref) {
        # if only one subtunnel is applicable (no overtaking/reordering produced)
        # just return that one
        $ALGOLOG->INFO("%f  llfmt_ll_selector(): only got 1 good subtun_hash as input return that", sub { return time() - $start_time; });
        return $sock_hashes_ref->[0]->{sock_id};
    }

    for my $sock_hash (@$sock_hashes_ref) {
        if ( $sock_hash->{srtt} < $minimal_srtt) {
            $minimal_srtt = $sock_hash->{srtt};
            $opti_sock_id = $sock_hash->{sock_id};
        }
    }

    if ( $opti_sock_id == -1) { # found no opti sock
        $ALGOLOG->WARN("%f  llfmt_ll_selector: Found no usable socket/subtun", sub { return time() - $start_time; });
        return -1;
    }

    $ALGOLOG->INFO("%f  llfmt_ll_selector: selected $opti_sock_id, with srtt: $minimal_srtt", sub { return time() - $start_time; });
    return $opti_sock_id;
}

sub afmt_base_adaptivity
{
    my $sock_hashes_ref = shift;
    my $max_weighted_free_slots = 0;
    my $opti_sock_id = -1;

    if ( 1 == @$sock_hashes_ref) {
        # if only one subtunnel is applicable (no overtaking/reordering produced)
        # just return that one
        $ALGOLOG->INFO("%f  afmt_base_adaptivity(): only got 1 good subtun_hash as input return that", sub { return time() - $start_time; });
        return $sock_hashes_ref->[0]->{sock_id};
    }

    for my $subtun_hash (@$sock_hashes_ref) {
        my $weighted_free_slots = log( ($subtun_hash->{send_rate} - $subtun_hash->{in_flight}) )
            / ($subtun_hash->{srtt} ||  10_000);

        $ALGOLOG->NOTICE("%f  afmt_base_adaptivity(): sock_id: $subtun_hash->{sock_id}"
                             . " | srtt:" . $subtun_hash->{srtt} . "us"
                             . " | cwnd:" . ($subtun_hash->{send_rate})
                             . " | in flight packets: $subtun_hash->{in_flight}"
                             . " | resulting weighted_free_slots: $weighted_free_slots", sub { return time() - $start_time; });

        if ( $weighted_free_slots > $max_weighted_free_slots ) {
            $max_weighted_free_slots = $weighted_free_slots;
            $opti_sock_id = $subtun_hash->{sock_id};
        }
    }
    $ALGOLOG->NOTICE("%f  afmt_base_adaptivty: selected $opti_sock_id, with weighted free slots: $max_weighted_free_slots", sub { return time() - $start_time; });
    return $opti_sock_id;
}

sub send_scheduler_rr
{
    # State is same as static for local variables in C
    # Value of variables is persistent between function calls, because stored on the heap
    state $current_subtun_id = 0;
    my $subtun_count = @subtun_sessions;

    if ( $subtun_count == 0) {
        $ALGOLOG->WARN("send_scheduler_rr called with no subtunnels???");
        return;
    }

    $ALGOLOG->NOTICE("RR: chosen socket: $current_subtun_id");
    sysread($_[HEAP]->{tun_device}, my $packet , TUN_MAX_FRAME );
    $poe_kernel->call( $subtun_sessions[$current_subtun_id], "on_data_to_send", $packet );

    $current_subtun_id = ($current_subtun_id+1) % $subtun_count;
    return 1;
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
        on_input        => \&dccp_subtun_recv,
        on_data_to_send => \&dccp_subtun_minimal_send,
        send_keepalive  => \&send_keepalive,
        on_connection_error => sub {
            my ($operation, $errnum, $errstr) = @_[ARG0, ARG1, ARG2];
            warn("Client $operation error $errnum: $errstr\n");
            delete $_[HEAP]{socket_factory};
            delete $_[HEAP]{subtun_sock};
        },
    }
    );

}

# Packet (received from subtun) hexdump layout:
# Our Header | 4 byte TunTap Hearder |  Payload IP Header | Payload TCP/UDP Header
sub dccp_subtun_recv
{
    my $curinput = undef;

    my $bytes_read = $_[HEAP]{subtun_sock}->sysread($curinput, 1600);
    $TXRXLOG->DEBUG("Recieved one DCCP packet. $bytes_read bytes");

    # if we're configured to use a tunnelling header
    if ( $own_header ) {
        # check the first byte (our header)
        # "a" ==> probe request ==> send probe response
        # "b" ==> probe response  ==> all fine, drop
        # "c" ==> data  ==> put into tap device

        # Sending a probe response is technically not necesary. (Our goal is to keep
        # the DCCP stats of the socket up to date, since DCCP automatically sends an ACK,
        # this happens anyway). But since the DCCP Ack could be a delayed ACK with this
        # we speed up and streamline the process.

        # This gets the first byte of $curinput and deletes it, in one call, quite cool
        my $header = bytes::substr($curinput, 0, 1, "");

        if ( $header eq "a") { # probe request
            # send probe response
            my $probe_response = "b" x 100;
            # XXX: Maybe this gives an encoding issue and we have to use
            # pack()/ unpack() here and above for the header bytes

            my $actually_sent_bytes =  $_[HEAP]->{subtun_sock}->syswrite($probe_response);
            if ((!defined($actually_sent_bytes))) { # syscall failed
                $TXRXLOG->ERR("%f  dccp_subtun_minimal_send(): socket error: errno: $!"
                              , sub { return time() - $start_time; });
            }

            # no further payload processing, just return
            return 1;
        } elsif ( $header eq "b") { # probe response
            return 2;
            # procssing done, only a probe response
            # do not put into tun device
        } elsif ( $header eq "c") { # payload packet
            # nothing to do here, just continue payload processing
            # header is already striped from packet
        } else {
            $TXRXLOG->WARN("%f  Got packet with broken header", sub { return time() - $start_time; });
            # die();
        }
    }

    $_[KERNEL]->call($tuntap_session => "put_into_tun_device", $curinput);
}

sub dccp_subtun_minimal_send
{
    my $payload = $_[ARG0];
    if ($own_header)
    {
        # here I need to prepend a "c"
        bytes::substr($payload, 0, 0, "c");

        # DONE: Mark subtun sock as used
        # 1. get sock id
        my $sock_id;
        for (my $i = 0; $i < @subtun_sessions; $i++) {
            if ($subtun_sessions[$i] == $_[SESSION]->ID()) {
                $sock_id = $i;
            }
        }
        # 2. set entry in recently_used array
        $recently_used[$sock_id] = 1;
    }

    # If loglevel is debug: ask dccp socket for max packet size and print it
    if ( $TXRXLOG->level() eq 'DEBUG' ) {
        my $packed = getsockopt($_[HEAP]{subtun_sock}, SOL_DCCP, DCCP_SOCKOPT_GET_CUR_MPS);
        my $max_packet_size = unpack("I", $packed);
        say("accepted subtun max packet size: $max_packet_size");
    }

    my $actually_sent_bytes =  $_[HEAP]->{subtun_sock}->syswrite($payload);
    if ((!defined($actually_sent_bytes))) {
        $TXRXLOG->ERR("%f  dccp_subtun_minimal_send(): socket error: errno: $!"
                          , sub { return time() - $start_time; });
    }
    # my $packet_size = bytes::length($payload)
    # $TXRXLOG->DEBUG("Sent payload through DCCP subtunnel $actually_sent_bytes of $packet_size bytes");
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
            on_data_received => \&dccp_subtun_recv,
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

# All availabale send schedulers, names with their implementation functions
my %sched_algos = (
    'rr'                     => \&send_scheduler_rr,
    'otias_sock_drop'        => \&send_scheduler_otias,
    'srtt_min_busy_wait'     => \&send_scheduler_srtt_min,
    'afmt_fl'                => \&send_scheduler_afmt_fl,
    'afmt_noqueue_drop'      => \&send_scheduler_afmt_noqueue_drop,
    'afmt_noqueue_busy_wait' => \&send_scheduler_afmt_noqueue_busy_wait,
    'llfmt_noqueue_busy_wait'=> \&send_scheduler_llfmt_noqueue_busy_wait
);

# set our scheduler from name got via cli param, die if invalid name
$packet_scheduler = $sched_algos{$sched_algo};
if ( !defined($packet_scheduler) ) {
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
## setting an interface and corresponding rules
POE::Session->create(
    inline_states => {
        _start => \&start_tun_session,
        got_packet_from_tun_device => $packet_scheduler,
        put_into_tun_device => \&tun_write,
    }
);

## DONE keepalive sender(r session) implementiernen
# - eigene session nehmen?
#   - welche existierende könnte ich nehmen
#   - ist ja vermutlich alles außerhalb von existierender
#   - ner subtun session anhängen ist blöd
#   - tuntab session würde gehen aber wär hässlich
#   - eigene ist eignetlich am schönsten
# - wie heißt die session dann was macht die?
#   - alle 100ms die eine funktion callen
#   - thats it
#   - oh und die könnte das recently_used array als variable haben
#     - ja das wär cool
# - was macht die funktion?
#   - über array iterieren und jedes mal
#     - kucken ob recently used
#       - wenn nicht:
#         - was senden
#         - auf 0 lassen
#       - wenn schon
#         - nichts tun
#         - recently used auf 0
# - was muss sende funktion machen?
#   - recently used auf 1

# DONE recently_used variable setzen wenn man wirklich sendet sinnvoll
#   - ist ja globale var (muss global sein damit andere sessions sie accessen können)
#   - und accessen wir hier:

# DONE: send_probe_response nimmer über simple_send() machen

# DONE: Payload übeall mit "c" preceden
#    - in der simple_send() machen
#    - muss dafür probe_response sending manuel ohne die simple_send() machen
# DONE: send_keepalive fertig machen
sub send_keepalive
{
    my $sock_id = $_[ARG0];
    my $keepalive_packet = "a" x 100;
    my $actually_sent_bytes =  $_[HEAP]->{subtun_sock}->syswrite($keepalive_packet);
    if ((!defined($actually_sent_bytes))) {
        $TXRXLOG->ERR("%f  dccp_subtun_minimal_send(): socket error: errno: $!"
                          , sub { return time() - $start_time; });
    }
    $CONLOG->INFO("[KEEPALIVE] %f  Sent a keepalive on subtunnel $sock_id",
                  sub {return time() - $start_time; # rel_time
                   });
}

if ($own_header)
{
    # Keepalive session
    # Arranges sending keep alive packets every 50ms
    # on subtunnels that are unused, to keep underlying proto stats up to date
    POE::Session->create(
        inline_states => {
            _start => sub {
                # runs once at start
                # should initialize all data structures
                # and schedule the next "uphold_subtunnels" in 50 ms
                $poe_kernel->delay( uphold_subtunnels => 0.05 );
            },
            uphold_subtunnels => sub {
                # Does the following:
                # * iterate over array and check if true
                #    - if yes call send_keepalive()
                # * schedule itself again in 50ms
                my $subtun_count = @subtun_sockets;

                for (my $i=0; $i < $subtun_count; $i++ ) {

                    if ( $recently_used[$i] ) {
                        $poe_kernel->call( $subtun_sessions[$i] , "send_keepalive", $i);
                    }

                    $recently_used[$i] = 0;
                }
                $poe_kernel->delay( uphold_subtunnels => 0.05 );
            },
        }
    );
}

set_via_tunnel_routes(1);
$start_time = time();

$poe_kernel->run();
