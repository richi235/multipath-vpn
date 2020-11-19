#!/bin/bash

# This executes (sources) run_experiment.sh multiple times in a row with different experiment params
# to have a series of experiments. This simplifies doing science and makes it more comfortable :)

# Sourcing means the current shell will execute the script instead of starting a new bash 
# Every experimnt script will place its result dir into our $series_dir by itself

runtime=60
flowcount=6
run=r1

series_dir="series_${runtime}s_${flowcount}flows_${run}"
udp_flag= #"-u"
bandwith_opt= #"-b20m"
hdr_opt="-hdr"

mkdir $series_dir

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

sched_algo=otias_sock_drop
echo -en "\e[32;1m[5/6]  \e[0m"
source ./run_experiment.sh

sched_algo=srtt_min_busy_wait
echo -en "\e[32;1m[6/6]  \e[0m"
source ./run_experiment.sh

#sched_algo=rr
#source ./run_experiment.sh

cd $series_dir
tail -n 4 */iperf_tentry.log > iperf_client_sums
tail -n 4 */iperf_server_output.log > iperf_server_sums

gnuplot ../all_throughput_intvervals_boxplots.plt ../all_SRTT_boxplots.plt

echo -e "\e[31;1mSeries dir: $series_dir\e[0m"
