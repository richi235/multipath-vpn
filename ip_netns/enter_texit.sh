#!/bin/bash

ip netns exec T_exit tmux new-session \
   'echo -e "\nUse: ./minimal_experiment_prototype.pl -c /etc/T_exit.cfg \n" ; and fish'
