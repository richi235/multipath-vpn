#!/bin/bash

ip netns exec T_entry tmux new-session \
   'echo -e "\nUse: ../minimal_experiment_prototype.pl -c T_entry.cfg --ccid=2 --sched=otias_sock_drop \n" ; and fish'
