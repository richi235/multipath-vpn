#!/bin/bash

# load dccp kernel module
modprobe dccp_ipv4

# Create the empty namespaces
ip netns add T_exit
ip netns add T_entry

# Create two interconnected veth interfaces
ip link add veth0 type veth peer name veth1

# Put the two interfaces into the two namespaces
ip link set veth0 netns T_entry
ip link set veth1 netns T_exit

# Configure the interface in T_entry
ip netns exec T_entry ip addr add 10.7.7.1/24 dev veth0
ip netns exec T_entry ip link set veth0 up

# Configure the interface in T_exit
ip netns exec T_exit ip addr add 10.7.7.2/24 dev veth1
ip netns exec T_exit ip link set veth1 up
