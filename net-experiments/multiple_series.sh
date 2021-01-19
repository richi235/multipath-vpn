#!/bin/bash

# In our lingo a series is a number of experiments, all with the same network configuration
# evaluating several different scheduling algorithms (5-6). experiment_series.sh is responsible
# for running such a series

# This script makes it possible to set network configuration, run a series, change network
# configuration, run another series etc. to give a maximum of automatiton benefit :)

# You have to use this as entry points for all experiments, calling experiment_series.sh
# is no longer possible


# Was ich über dieses script noch nicht ändern/automatisieren kann:
#  - CCID einstelllung
#  - wie viele tunnels wir benutzen


# TODO: noch entscheiden wie ich das sinnvoll mit prefixes und unterordnen mache

investigation_prefix=rtt_asym_1

runtime=70
warmup_seconds=10
flowcount=4
udp_flag= #"-u"
bandwith_opt= #"-b3m"
hdr_opt= #"-hdr"

ig0_rtt=50    # in ms
ig0_rate=8mbit

ig1_rtt=50
ig1_rate=8mbit

ig2_rtt=50
ig2_rate=8mbit


source ./experiment_series.sh


ig1_rtt=70
ig2_rtt=50

source ./experiment_series.sh

ig1_rtt=100
ig2_rtt=50

source ./experiment_series.sh

mkdir $investigation_prefix
mv ${investigation_prefix}:series*  $investigation_prefix
cp "$(readlink -f $0)" $investigation_prefix # archive this script too, as reference

