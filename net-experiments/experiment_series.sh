#!/bin/bash

# This executes (sources) run_experiment.sh multiple times in a row with different experiment params
# to have a series of experiments. This simplifies doing science and makes it more comfortable :)

# Sourcing means the current shell will execute the script instead of starting a new bash 


runtime=30
flowcount=6
run=r1
udp_flag= #"-u"
bandwith_opt= #"-b20m"
hdr_opt= #"-hdr"

sched_algo=llfmt_noqueue_busy_wait  
source ./run_experiment.sh

sched_algo=afmt_noqueue_busy_wait
source ./run_experiment.sh

sched_algo=afmt_noqueue_drop
source ./run_experiment.sh

sched_algo=afmt_fl
source ./run_experiment.sh

sched_algo=otias_sock_drop
source ./run_experiment.sh

sched_algo=srtt_min_busy_wait
source ./run_experiment.sh

sched_algo=rr
source ./run_experiment.sh



