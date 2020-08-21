#!/bin/bash
# This runs a experiment with einsfroest. And generates some graphs from it
# (packet delay variation and throughput). This is the server side (T_exit)

runtime=10
sched_algo=afmt_noqueue_drop
udp_flag="-u -l 1392"
bandwith_opt="-b2m"
flowcount=1
run=r1
results_dir="${runtime}s_${sched_algo}_${udp_flag}_${flowcount}flows_${bandwith_opt}_$run"   # the dir the results will be stored in
echo $results_dir
mkdir $results_dir


# Dev note: Maybe use:  timeout 10 (timeout is a own program, seconds is default type)
timeout $((runtime+7)) ../minimal_experiment_prototype.pl -c ../ip_netns/T_exit.cfg  \
              --sched=$sched_algo --ccid=2 > $results_dir/texit_logs  &
sleep 1

timeout $((runtime+5)) tcpdump -i tun0 -w afmt_tun0_trace.pcap "dst 192.168.65.2" &
timeout $((runtime+4)) iperf $udp_flag  -s -i 0.1 --reportstyle C > iperf_server_output.csv &

ip netns exec T_entry timeout $((runtime+4)) ../minimal_experiment_prototype.pl \
            -c ../ip_netns/T_entry.cfg --sched=$sched_algo --ccid=2 \
            --lcon=INFO  > tentry_logs & 
sleep 1
ip netns exec T_entry iperf $udp_flag  -t $runtime $bandwith_opt  \
		            -c 192.168.65.2 -i 0.1  -P $flowcount  > iperf_tentry.log &

sleep $((runtime+3))

## ----- here we block for 12 seconds, after that
## ----- generatiing graphs starts:

cut -d, -f 9 iperf_server_output.csv > server_bps

./get_delay_variations.py afmt_tun0_trace.pcap > delay_variations


gnuplot packet_delay_variation_plot.plt
gnuplot throughput.plt
# rm afmt_tun0_trace.pcap
mv tentry_logs iperf_server_output.csv iperf_tentry.log  delay_variations server_bps afmt_pdv.pdf Throughput.pdf $results_dir
