#!/bin/bash
# This runs a experiment with einsfroest. And generates some graphs from it
# (throughput). This is intended to run on the server side (T_exit)

create_results_dir()
{
    results_dir="${sched_algo}"   # the dir the results will be stored in
    echo -e "\e[31;1m$results_dir \e[0m"
    mkdir $results_dir
    #udp_flag=${udp_flag}" -l 1392" # added after mkdir because spaces are hard + unneeded info in dir name
}
create_results_dir

tentry_ssh_dest="root@tentry"
other_ctx_prefix="ssh $tentry_ssh_dest"
# other_ctx_prefix="ip netns exec T_entry"

timeout $((runtime+18)) ../minimal_experiment_prototype.pl  \
              --sched=$sched_algo $hdr_opt --ccid=$CCID > /tmp/texit_logs  &
sleep 1

start_tcpdump()
{
    # Here on T_exit.
    # Two instances: one inside tunnel, one outside
    timeout $((runtime+5)) tcpdump -i tun0 -w afmt_tun0_trace.pcap "dst 192.168.65.2" &
    timeout $((runtime+5)) tcpdump -i veth12 -w afmt_veth12.pcap "proto dccp" &
}


start_tunnel_and_iperf_on_tentry()
{
    $other_ctx_prefix "timeout $((runtime+16)) ~/Coding/Reinhard-VPN/minimal_experiment_prototype.pl \
                --sched=$sched_algo --ccid=$CCID \
                --lcon=INFO  --lalgo=NOTICE  $hdr_opt --lsci=NOTICE  > /tmp/tentry_logs" &
    sleep 3
    $other_ctx_prefix "$probe_cmd $udp_flag  -t $runtime $bandwith_opt  \
                    -c 192.168.65.2 -i $iperf_report_interval -e -f m  -P $flowcount  > /tmp/iperf_tentry.log" &
}
start_tunnel_and_iperf_on_tentry

sleep $((runtime+17))
## ----- here we block for 17 seconds. After that
## ----- generatiing graphs starts:


# mal schuen: wo landet die datei wenn relativer pfad bei ssh remote command
#  antwort: im homedir, as expected

get_logs_from_tentry()
{
    # if we used ssh copy log files from other host to us:
    # uses bash regex matching, checks if prefx starts with "ssh "
    if [[ $other_ctx_prefix =~ ^ssh[[:blank:]]  ]] ; then
        scp -q "$tentry_ssh_dest:/tmp/{*tentry*log*,time_inflight*.tsv}" .
    fi
}
get_logs_from_tentry

mv /tmp/texit_logs $results_dir

generate_delay_variation_plot()
{
    # Doesn't really work currently, assumes TCP, and doesn't get negative PDVs
    ./get_delay_variations.py afmt_tun0_trace.pcap > delay_variations
    gnuplot packet_delay_variation_plot.plt
}

generate_subtun_diagrams()
{
    ./demux_subtun_records.pl time_inflight_cwnd_srtt.tsv
    gnuplot all_subtuns_time_inflight_cwnd.plt # tunnel internal infos
}
generate_subtun_diagrams

optional_plots()
{
    gnuplot SRTT_boxplot.plt
    gnuplot throughput2.plt
}

after_experiment_cleanup()
{
    # grep --fixed-strings "tc -netns" ../ip_netns/setup_namespaces_and_network.sh > $results_dir/network_conf
    # rm afmt_tun0_trace.pcap
    # rm *.tsv
    mv *.tsv all_subtuns_time_inflight_cwnd.pdf  SRTTs.pdf  tentry_logs iperf_tentry.log $results_dir
    # Compress the longer log/data files still viewable with vim
    gzip $results_dir/*_logs
    gzip $results_dir/*.tsv
    # delay_variations afmt_pdv.pdf Throughput.pdf 
    mv $results_dir $series_dir
}
after_experiment_cleanup

# TODO: Maybe we can remove this:
sleep 15s
#pkill $probe_cmd # kill leftover $probe_cmd server on texit if it still exists
#sleep 2s
#killall $probe_cmd
#sleep 10s
