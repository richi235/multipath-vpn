require '_h2ph_pre.ph';

no warnings qw(redefine misc);

unless(defined(&DCCP_DCCP_H)) {
    eval 'sub DCCP_DCCP_H () {1;}' unless defined(&DCCP_DCCP_H);
    eval 'sub SOL_DCCP () {269;}' unless defined(&SOL_DCCP);
    eval 'sub DCCP_SOCKOPT_SERVICE () {2;}' unless defined(&DCCP_SOCKOPT_SERVICE);
    eval 'sub DCCP_SOCKOPT_CHANGE_L () {3;}' unless defined(&DCCP_SOCKOPT_CHANGE_L);
    eval 'sub DCCP_SOCKOPT_CHANGE_R () {4;}' unless defined(&DCCP_SOCKOPT_CHANGE_R);
    eval 'sub DCCP_SOCKOPT_GET_CUR_MPS () {5;}' unless defined(&DCCP_SOCKOPT_GET_CUR_MPS);
    eval 'sub DCCP_SOCKOPT_SERVER_TIMEWAIT () {6;}' unless defined(&DCCP_SOCKOPT_SERVER_TIMEWAIT);
    eval 'sub DCCP_SOCKOPT_SEND_CSCOV () {10;}' unless defined(&DCCP_SOCKOPT_SEND_CSCOV);
    eval 'sub DCCP_SOCKOPT_RECV_CSCOV () {11;}' unless defined(&DCCP_SOCKOPT_RECV_CSCOV);
    eval 'sub DCCP_SOCKOPT_AVAILABLE_CCIDS () {12;}' unless defined(&DCCP_SOCKOPT_AVAILABLE_CCIDS);
    eval 'sub DCCP_SOCKOPT_CCID () {13;}' unless defined(&DCCP_SOCKOPT_CCID);
    eval 'sub DCCP_SOCKOPT_TX_CCID () {14;}' unless defined(&DCCP_SOCKOPT_TX_CCID);
    eval 'sub DCCP_SOCKOPT_RX_CCID () {15;}' unless defined(&DCCP_SOCKOPT_RX_CCID);
    eval 'sub DCCP_SOCKOPT_QPOLICY_ID () {16;}' unless defined(&DCCP_SOCKOPT_QPOLICY_ID);
    eval 'sub DCCP_SOCKOPT_QPOLICY_TXQLEN () {17;}' unless defined(&DCCP_SOCKOPT_QPOLICY_TXQLEN);
    eval 'sub DCCP_SOCKOPT_CCID_RX_INFO () {128;}' unless defined(&DCCP_SOCKOPT_CCID_RX_INFO);
    eval 'sub DCCP_SOCKOPT_CCID_TX_INFO () {192;}' unless defined(&DCCP_SOCKOPT_CCID_TX_INFO);
}
1;
