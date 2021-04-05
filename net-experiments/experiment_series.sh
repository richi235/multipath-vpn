#!/bin/bash

# This executes (sources) run_experiment.sh multiple times in a row with different experiment params
# to have a series of experiments. This simplifies doing science and makes it more comfortable :)

# Sourcing means the current shell will execute the script instead of starting a new bash 
# Every experimnt script will place its result dir into our $series_dir by itself

probe_cmd=iperf
iperf_report_interval=1


echo "Setting path characteristics on all subtunnel paths..."
# ig0
ssh root@ig0 "tc qdisc change dev eth0.11 root netem delay $((ig0_rtt/2))ms rate $ig0_rate"
ssh root@ig0 "tc qdisc change dev eth0.21 root netem delay $((ig0_rtt/2))ms rate $ig0_rate"

# ig1
ssh root@ig1 "tc qdisc change dev eth0.12 root netem delay $((ig1_rtt/2))ms rate $ig1_rate"
ssh root@ig1 "tc qdisc change dev eth0.22 root netem delay $((ig1_rtt/2))ms rate $ig1_rate"

# ig2
ssh root@ig2 "tc qdisc change dev eth0.13 root netem delay $((ig2_rtt/2))ms rate $ig2_rate"
ssh root@ig2 "tc qdisc change dev eth0.23 root netem delay $((ig2_rtt/2))ms rate $ig2_rate"

ssh root@tentry " cd /proc/sys/net/dccp/default ; echo $CCID > rx_ccid ; echo $CCID > tx_ccid"

echo "Done!"

echo $CCID > /proc/sys/net/dccp/default/rx_ccid ; echo $CCID > /proc/sys/net/dccp/default/tx_ccid


series_dir="${investigation_prefix}:series_${runtime}s_${udp_flag}_${bandwith_opt}_${flowcount}flows_${run}_${hdr_opt}_2subtun__ig1:${ig1_rtt}ms,${ig1_rate}__ig2:${ig2_rtt}ms,${ig2_rate}_$CCID"

mkdir $series_dir

$probe_cmd  -s -i 0.1  > iperf_server_output.log  &

sched_algo=llfmt_noqueue_busy_wait  
echo -en "\e[32;1m[1/6]  \e[0m"
source ./run_experiment.sh 

sched_algo=afmt_noqueue_busy_wait
echo -en "\e[32;1m[2/6]  \e[0m"
source ./run_experiment.sh

sched_algo=afmt_noqueue_drop
echo -en "\e[32;1m[3/6]  \e[0m"
source ./run_experiment.sh

sched_algo=afmt_fl
echo -en "\e[32;1m[4/6]  \e[0m"
source ./run_experiment.sh

hdr_opt= #"-hdr"
sched_algo=otias_sock_drop
echo -en "\e[32;1m[5/6]  \e[0m"
source ./run_experiment.sh

sched_algo=srtt_min_busy_wait
echo -en "\e[32;1m[6/6]  \e[0m"
source ./run_experiment.sh

#sched_algo=rr
#source ./run_experiment.sh

killall $probe_cmd
sleep 2s
mv iperf_server_output.log $series_dir
cd $series_dir
tail -n 4 */iperf_tentry.log > iperf_client_sums
# tail -n 4 */iperf_server_output.log > iperf_server_sums

# This calculates the number of record lines (rls) that happen during the warmup time
# i.e. that we have to skip. rls are lines that contain valuable records, i.e. lines that are
# returned by the grep commands we use for pseudofile input.
#
# Q: Are the rls of the two different gnuplot invocations the same? 
# A: Most likely there should only be a different and the end (all_SRTTs does use the 00-20s per flow lines)
#
# Getting rls from the pseudofile means we need not skip the header lines or connect info lines, it is already filtered out
# So it's: ($warmup_seconds/$iperf_report_interval) * $flowcount
#  - Per report interval there's 1 rl for every flow
#  - If we have report interval 0.1 s and 1s warmup time. theres 1/0.1 = 10 reports

# The $(( )) is to start the arithmetic evaluation mode of the bash, see man bash

rls_to_ignore=$(( (warmup_seconds/iperf_report_interval) * flowcount))
echo "rls_to_ignore: $rls_to_ignore"

plot_SRTT_boxplots()
{
    # all_SRTT_boxplots.plt
    gnuplot  <<PLOT
    # This generates boxplot diagramms of the RTTs directly from the iperf output files
    set terminal pdf
    set output "SRTTs.pdf"
    set title "SRTTs"
    set ylabel "ms"
    unset xlabel

    set style fill solid 0.5 border -1
    set style data boxplot
    set style boxplot nooutliers
    #set boxwidth  0.5

    plot '<grep -P -o "(?<=K/)(\d*)(?= us )" afmt_noqueue_drop/iperf_tentry.log' skip $rls_to_ignore using (0.5):(column(1)/1000) title 'afmt\_noqueue\_drop' \
    , '<grep -P -o "(?<=K/)(\d*)(?= us )" afmt_fl/iperf_tentry.log' skip $rls_to_ignore using (1.5):(column(1)/1000) title 'afmt\_fl'\
    , '<grep -P -o "(?<=K/)(\d*)(?= us )" otias_sock_drop/iperf_tentry.log' skip $rls_to_ignore using (2.5):(column(1)/1000) title 'otias\_sock\_drop' \
    , '<grep -P -o "(?<=K/)(\d*)(?= us )" srtt_min_busy_wait/iperf_tentry.log' skip $rls_to_ignore using (3.5):(column(1)/1000) title 'srtt\_min\_busy\_wait' \
    , '<grep -P -o "(?<=K/)(\d*)(?= us )" afmt_noqueue_busy_wait/iperf_tentry.log' skip $rls_to_ignore using (4.5):(column(1)/1000) title 'afmt\_noqueue\_busy\_wait' \
    , '<grep -P -o "(?<=K/)(\d*)(?= us )" llfmt_noqueue_busy_wait/iperf_tentry.log' skip $rls_to_ignore using (5.5):(column(1)/1000) title 'llfmt\_noqueue\_busy\_wait'

    # about: (0.5):(column(1)/1000)
    # the 0.5 is the x value where this boxplot box will be placed
    # column(1) is the column of the data file used , 0 would be the record number
    PLOT
}

plot_retransmissions()
{
    # Retransmissions.plt
    gnuplot  <<PLOT
    # This generates boxplot diagramms of the Retransmissions/Retries directly from the iperf output files
    set terminal pdf
    set output "Retransmissions.pdf"
    set title "Retransmissions"
    set ylabel "count"
    unset xlabel

    set style fill solid 0.5 border -1
    set style data boxplot
    set style boxplot nooutliers
    #set boxwidth  0.5

    plot '<grep -P -o  "\d+(?=\s+\d*K/\d* us )"  afmt_noqueue_drop/iperf_tentry.log' skip $rls_to_ignore using (0.5):(column(1)/1000) title 'afmt\_noqueue\_drop' \
    , '<grep -P -o  "\d+(?=\s+\d*K/\d* us )"  afmt_fl/iperf_tentry.log' skip $rls_to_ignore using (1.5):(column(1)/1000) title 'afmt\_fl'\
    , '<grep -P -o  "\d+(?=\s+\d*K/\d* us )"  otias_sock_drop/iperf_tentry.log' skip $rls_to_ignore using (2.5):(column(1)/1000) title 'otias\_sock\_drop' \
    , '<grep -P -o  "\d+(?=\s+\d*K/\d* us )"  srtt_min_busy_wait/iperf_tentry.log' skip $rls_to_ignore using (3.5):(column(1)/1000) title 'srtt\_min\_busy\_wait' \
    , '<grep -P -o  "\d+(?=\s+\d*K/\d* us )"  afmt_noqueue_busy_wait/iperf_tentry.log' skip $rls_to_ignore using (4.5):(column(1)/1000) title 'afmt\_noqueue\_busy\_wait' \
    , '<grep -P -o  "\d+(?=\s+\d*K/\d* us )"  llfmt_noqueue_busy_wait/iperf_tentry.log' skip $rls_to_ignore using (5.5):(column(1)/1000) title 'llfmt\_noqueue\_busy\_wait'

    # about: (0.5):(column(1)/1000)
    # the 0.5 is the x value where this boxplot box will be placed
    # column(1) is the column of the data file used , 0 would be the record number
    PLOT
}

plot_throughput_intervals()
{
    # all_throughput_intvervals_boxplots.plt
    gnuplot  <<PLOT
    # This generates a boxplot diagrmm of the Throughputs per 0.1s interval directly from the iperf output

    set terminal pdf
    set output "Throughputs_per_interval.pdf"
    set title "Throughputs per interval"
    set ylabel "Mbit/s"
    unset xlabel

    set style fill solid 0.5 border -1
    set style data boxplot
    set style boxplot nooutliers
    #set boxwidth  0.5

    plot '<grep -v -e "^\[SUM\]" -e "0\.0000-[1-9][0-9]"  afmt_noqueue_drop/iperf_tentry.log |  grep -P -o "( \d+\.\d+)(?= Mbits/sec )"' skip $rls_to_ignore using (0.5):(column(1)) title 'afmt\_noqueue\_drop' \
    , '<grep -v -e "^\[SUM\]" -e "0\.0000-[1-9][0-9]"  afmt_fl/iperf_tentry.log |  grep -P -o "( \d+\.\d+)(?= Mbits/sec )"' skip $rls_to_ignore using (1.5):(column(1)) title 'afmt\_fl'\
    , '<grep -v -e "^\[SUM\]" -e "0\.0000-[1-9][0-9]"  otias_sock_drop/iperf_tentry.log |  grep -P -o "( \d+\.\d+)(?= Mbits/sec )"' skip $rls_to_ignore using (2.5):(column(1)) title 'otias\_sock\_drop' \
    , '<grep -v -e "^\[SUM\]" -e "0\.0000-[1-9][0-9]"  srtt_min_busy_wait/iperf_tentry.log |  grep -P -o "( \d+\.\d+)(?= Mbits/sec )"' skip $rls_to_ignore using (3.5):(column(1)) title 'srtt\_min\_busy\_wait' \
    , '<grep -v -e "^\[SUM\]" -e "0\.0000-[1-9][0-9]"  afmt_noqueue_busy_wait/iperf_tentry.log |  grep -P -o "( \d+\.\d+)(?= Mbits/sec )"' skip $rls_to_ignore using (4.5):(column(1)) title 'afmt\_noqueue\_busy\_wait' \
    , '<grep -v -e "^\[SUM\]" -e "0\.0000-[1-9][0-9]"  llfmt_noqueue_busy_wait/iperf_tentry.log |  grep -P -o "( \d+\.\d+)(?= Mbits/sec )"' skip $rls_to_ignore using (5.5):(column(1)) title 'llfmt\_noqueue\_busy\_wait'
    PLOT
}


# also create the fancy publication diagrams
gnuplot ../throughput_publication.plt  ../SRTTs_boxplot_publication.plt


# Write a file with our path config
echo "ig0:" 		   		> path_config
ssh root@ig0 "ip r ; and tc qdisc ls"   >> path_config
echo "ig1:" 		   		>> path_config
ssh root@ig1 "ip r ; and tc qdisc ls"   >> path_config
echo "ig2:" 		   		>> path_config
ssh root@ig2 "ip r ; and tc qdisc ls"   >> path_config

scp root@tentry:/etc/multivpn.cfg tentry_multivpn.cfg
cp  /etc/multivpn.cfg texit_multivpn.cfg

echo -e "\e[31;1mSeries dir: $series_dir\e[0m"

cd .. # necesarry since were sourced by multiple_series.sh so it can continue where it was
