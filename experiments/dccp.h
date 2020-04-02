/* This file only contains constants necessary for user space to call
 * into the kernel and thus, contains no copyrightable information. */

#ifndef DCCP_DCCP_H
#define DCCP_DCCP_H

// From the kernel's include/linux/socket.h
#define SOL_DCCP                        269

// From kernel's include/uapi/linux/dccp.h
#define DCCP_SOCKOPT_SERVICE            2
#define DCCP_SOCKOPT_CHANGE_L           3
#define DCCP_SOCKOPT_CHANGE_R           4
#define DCCP_SOCKOPT_GET_CUR_MPS        5
#define DCCP_SOCKOPT_SERVER_TIMEWAIT    6
#define DCCP_SOCKOPT_SEND_CSCOV         10
#define DCCP_SOCKOPT_RECV_CSCOV         11
#define DCCP_SOCKOPT_AVAILABLE_CCIDS    12
#define DCCP_SOCKOPT_CCID               13
#define DCCP_SOCKOPT_TX_CCID            14
#define DCCP_SOCKOPT_RX_CCID            15
#define DCCP_SOCKOPT_QPOLICY_ID         16
#define DCCP_SOCKOPT_QPOLICY_TXQLEN     17
#define DCCP_SOCKOPT_CCID_RX_INFO       128
#define DCCP_SOCKOPT_CCID_TX_INFO       192


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
 *			  with last_win_count value sent
 * @tx_no_feedback_timer: Handle to no feedback timer
 * @tx_t_ld:		  Time last doubled during slow start
 * @tx_t_nom:		  Nominal send time of next packet
 * @tx_hist:		  Packet history
 */
struct tfrc_tx_info {
    uint64_t tfrctx_x;
    uint64_t tfrctx_x_recv;
    uint32_t tfrctx_x_calc;
    uint32_t tfrctx_rtt;
    uint32_t tfrctx_p;
    uint32_t tfrctx_rto;
    uint32_t tfrctx_ipi;
};

#define DCCP_SOCKOPT_CCID_TX_INFO       192



#endif //DCCP_DCCP_H
