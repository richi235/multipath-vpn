#!/bin/bash
# This runs a experiment with einsfroest. And generates some graphs from it
# (packet delay variation and throughput). This is the server side (T_exit)

results_dir="${runtime}s_${sched_algo}_${udp_flag}_${flowcount}flows_${bandwith_opt}_${hdr_opt}"   # the dir the results will be stored in
echo -e "\e[31;1m$results_dir \e[0m"
mkdir $results_dir
#udp_flag=${udp_flag}" -l 1392" # added after mkdir because spaces are hard + unneeded info in dir name

# other_ctx_prefix="ip netns exec T_entry"
tentry_ssh_dest="root@tentry"
other_ctx_prefix="ssh $tentry_ssh_dest"

timeout $((runtime+28)) ../minimal_experiment_prototype.pl  \
              --sched=$sched_algo $hdr_opt --ccid=2 > $results_dir/texit_logs  &
sleep 1

#timeout $((runtime+5)) tcpdump -i tun0 -w afmt_tun0_trace.pcap "dst 192.168.65.2" &
# timeout $((runtime+5)) tcpdump -i veth12 -w afmt_veth12.pcap "proto dccp" &
#iperf3 $udp_flag  -s -i 0.1 --reportstyle C > iperf_server_output.csv &
iperf3 $udp_flag  -s -i 0.1  > iperf_server_output.log  &

$other_ctx_prefix "timeout $((runtime+26)) ~/Coding/Reinhard-VPN/minimal_experiment_prototype.pl \
             --sched=$sched_algo --ccid=2 \
            --lcon=INFO  --lalgo=NOTICE  $hdr_opt --lsci=NOTICE  > tentry_logs" &
sleep 1
$other_ctx_prefix "iperf3 $udp_flag  -t $runtime $bandwith_opt  \
		            -c 192.168.65.2 -i 0.1  -P $flowcount  > iperf_tentry.log" &

sleep $((runtime+27))

# todo: nachdenken über file locations
# idealerweise sind die commandos ja gleich für alle

# mal schuen: wo landet die datei wenn relativer pfad bei ssh remote command
#  antwort: im homedir, as expected

## ----- here we block for 12 seconds, after that
## ----- generatiing graphs starts:

# if we used ssh copy log files from other host to us:
# uses bash regex matching, checks if prefx starts with "ssh "
if [[ $other_ctx_prefix =~ ^ssh[[:blank:]]  ]] ; then
    scp -q "$tentry_ssh_dest:{*tentry*log*,time_inflight*.tsv}" .
fi

#./get_delay_variations.py afmt_tun0_trace.pcap > delay_variations
./demux_subtun_records.pl time_inflight_cwnd_srtt.tsv

gnuplot all_subtuns_time_inflight_cwnd.plt # tunnel internal infos
#gnuplot packet_delay_variation_plot.plt
# gnuplot throughput2.plt   SRTT_boxplot.plt
# grep --fixed-strings "tc -netns" ../ip_netns/setup_namespaces_and_network.sh > $results_dir/network_conf
# rm afmt_tun0_trace.pcap
# rm *.tsv
mv *.tsv all_subtuns_time_inflight_cwnd.pdf  tentry_logs iperf_server_output.log iperf_tentry.log $results_dir
# delay_variations afmt_pdv.pdf Throughput.pdf SRTTs.pdf


#exit

mv $results_dir $series_dir

sleep 5s
pkill iperf3 # kill leftover iperf3 server on texit if it still exists
sleep 2s
killall iperf3
sleep 10s
