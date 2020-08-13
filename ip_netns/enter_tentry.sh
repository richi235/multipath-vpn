#!/bin/bash

ip netns exec T_entry tmux new-session \
   'echo -e "\nUse: ./minimal_experiment_prototype.pl -c /etc/T_entry.cfg \n" ; and fish'
