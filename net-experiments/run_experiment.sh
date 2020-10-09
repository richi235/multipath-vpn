#!/bin/bash
# This runs a experiment with einsfroest. And generates some graphs from it
# (packet delay variation and throughput). This is the server side (T_exit)

runtime=5
#sched_algo=llfmt_noqueue_busy_wait  
sched_algo=afmt_noqueue_busy_wait
#sched_algo=otias_sock_drop
#sched_algo=srtt_min_busy_wait
udp_flag= #"-u"
bandwith_opt= #"-b20m"
flowcount=6
hdr_opt= #"-hdr"
run=r2_new_net
results_dir="${runtime}s_${sched_algo}_${udp_flag}_${flowcount}flows_${bandwith_opt}_${hdr_opt}_$run"   # the dir the results will be stored in
echo $results_dir
mkdir $results_dir
#udp_flag=${udp_flag}" -l 1392" # added after mkdir because spaces are hard + unneeded info in dir name

# other_ctx_prefix="ip netns exec T_entry"
other_ctx_prefix="ssh root@tentry"

timeout $((runtime+7)) ../minimal_experiment_prototype.pl -c ../ip_netns/T_exit.cfg  \
              --sched=$sched_algo $hdr_opt --ccid=2 > $results_dir/texit_logs  &
sleep 1

#timeout $((runtime+5)) tcpdump -i tun0 -w afmt_tun0_trace.pcap "dst 192.168.65.2" &
# timeout $((runtime+5)) tcpdump -i veth12 -w afmt_veth12.pcap "proto dccp" &
timeout $((runtime+4)) iperf $udp_flag  -s -i 0.1 --reportstyle C > iperf_server_output.csv &

$other_ctx_prefix timeout $((runtime+4)) ~/Coding/Reinhard-vpn/minimal_experiment_prototype.pl \
            -c ../ip_netns/T_entry.cfg --sched=$sched_algo --ccid=2 \
            --lcon=INFO  --lalgo=NOTICE  $hdr_opt --lsci=NOTICE  > tentry_logs &
sleep 1
$other_ctx_prefix iperf $udp_flag  -t $runtime $bandwith_opt  \
		            -e -c 192.168.65.2 -i 0.1  -P $flowcount  > iperf_tentry.log &

sleep $((runtime+3))

## ----- here we block for 12 seconds, after that
## ----- generatiing graphs starts:

#./get_delay_variations.py afmt_tun0_trace.pcap > delay_variations
./demux_subtun_records.pl time_inflight_cwnd_srtt.tsv

gnuplot all_subtuns_time_inflight_cwnd.plt # tunnel internal infos
#gnuplot packet_delay_variation_plot.plt
gnuplot throughput2.plt   SRTT_boxplot.plt
grep --fixed-strings "tc -netns" ../ip_netns/setup_namespaces_and_network.sh > $results_dir/network_conf
# rm afmt_tun0_trace.pcap
# rm *.tsv
mv *.tsv all_subtuns_time_inflight_cwnd.pdf SRTTs.pdf  tentry_logs iperf_server_output.csv iperf_tentry.log  delay_variations afmt_pdv.pdf Throughput.pdf $results_dir
