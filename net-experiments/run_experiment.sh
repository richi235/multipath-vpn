#!/bin/bash
# This runs a experiment with einsfroest. And generates some graphs from it
# (packet delay variation and throughput). This is the server side (T_exit)

results_dir="${sched_algo}"   # the dir the results will be stored in
echo -e "\e[31;1m$results_dir \e[0m"
mkdir $results_dir
#udp_flag=${udp_flag}" -l 1392" # added after mkdir because spaces are hard + unneeded info in dir name

# other_ctx_prefix="ip netns exec T_entry"
tentry_ssh_dest="root@tentry"
other_ctx_prefix="ssh $tentry_ssh_dest"

timeout $((runtime+18)) ../minimal_experiment_prototype.pl  \
              --sched=$sched_algo $hdr_opt --ccid=2 > /tmp/texit_logs  &
sleep 1

#timeout $((runtime+5)) tcpdump -i tun0 -w afmt_tun0_trace.pcap "dst 192.168.65.2" &
# timeout $((runtime+5)) tcpdump -i veth12 -w afmt_veth12.pcap "proto dccp" &
#$probe_cmd $udp_flag  -s -i 0.1 --reportstyle C > iperf_server_output.csv &

$other_ctx_prefix "timeout $((runtime+16)) ~/Coding/Reinhard-VPN/minimal_experiment_prototype.pl \
             --sched=$sched_algo --ccid=2 \
            --lcon=INFO  --lalgo=NOTICE  $hdr_opt --lsci=NOTICE  > /tmp/tentry_logs" &
sleep 3
$other_ctx_prefix "$probe_cmd $udp_flag  -t $runtime $bandwith_opt  \
		            -c 192.168.65.2 -i $iperf_report_interval -e -f m  -P $flowcount  > /tmp/iperf_tentry.log" &

sleep $((runtime+17))
## ----- here we block for 12 seconds, after that
## ----- generatiing graphs starts:


# mal schuen: wo landet die datei wenn relativer pfad bei ssh remote command
#  antwort: im homedir, as expected

# if we used ssh copy log files from other host to us:
# uses bash regex matching, checks if prefx starts with "ssh "
if [[ $other_ctx_prefix =~ ^ssh[[:blank:]]  ]] ; then
    scp -q "$tentry_ssh_dest:/tmp/{*tentry*log*,time_inflight*.tsv}" .
fi

mv /tmp/texit_logs $results_dir
#./get_delay_variations.py afmt_tun0_trace.pcap > delay_variations
./demux_subtun_records.pl time_inflight_cwnd_srtt.tsv

gnuplot all_subtuns_time_inflight_cwnd.plt # tunnel internal infos
gnuplot   SRTT_boxplot.plt
#gnuplot packet_delay_variation_plot.plt
# gnuplot throughput2.plt 
# grep --fixed-strings "tc -netns" ../ip_netns/setup_namespaces_and_network.sh > $results_dir/network_conf
# rm afmt_tun0_trace.pcap
# rm *.tsv
mv *.tsv all_subtuns_time_inflight_cwnd.pdf  SRTTs.pdf  tentry_logs iperf_tentry.log $results_dir

# Compress the longer log/data files still viewable with vim
gzip $results_dir/*_logs
gzip $results_dir/*.tsv
# delay_variations afmt_pdv.pdf Throughput.pdf 


#exit

mv $results_dir $series_dir

sleep 15s
#pkill $probe_cmd # kill leftover $probe_cmd server on texit if it still exists
#sleep 2s
#killall $probe_cmd
#sleep 10s
