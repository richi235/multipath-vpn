#!/bin/bash

# load dccp kernel module
modprobe dccp_ipv4

# Create the empty namespaces
ip netns add T_exit
ip netns add T_entry

# Create 6 pairwise interconnected veth interfaces
ip link add veth11 type veth peer name veth12
ip link add veth21 type veth peer name veth22
ip link add veth31 type veth peer name veth32

# Put the interfaces into the respective namespaces
ip link set veth11 netns T_entry
ip link set veth21 netns T_entry
ip link set veth31 netns T_entry

ip link set veth12 netns T_exit
ip link set veth22 netns T_exit
ip link set veth32 netns T_exit

# Configure the interfaces in T_entry
ip netns exec T_entry ip addr add 1.0.0.1/24 dev veth11
ip netns exec T_entry ip link set veth11 up
tc -netns T_entry qdisc add dev veth11 root handle 20: netem delay 20ms rate 16mbit

ip netns exec T_entry ip addr add 2.0.0.1/24 dev veth21
ip netns exec T_entry ip link set veth21 up
tc -netns T_entry qdisc add dev veth21 root handle 20: netem delay 25ms rate 16mbit

ip netns exec T_entry ip addr add 3.0.0.1/24 dev veth31
ip netns exec T_entry ip link set veth31 up
tc -netns T_entry qdisc add dev veth31 root handle 20: netem delay 25ms rate 32mbit

# Configure the interfaces in T_exit
ip netns exec T_exit ip addr add 1.0.0.2/24 dev veth12
ip netns exec T_exit ip link set veth12 up
tc -netns T_exit qdisc add dev veth12 root handle 20: netem delay 20ms rate 16mbit

ip netns exec T_exit ip addr add 2.0.0.2/24 dev veth22
ip netns exec T_exit ip link set veth22 up
tc -netns T_exit qdisc add dev veth22 root handle 20: netem delay 25ms rate 16mbit

ip netns exec T_exit ip addr add 3.0.0.2/24 dev veth32
ip netns exec T_exit ip link set veth32 up
tc -netns T_exit qdisc add dev veth32 root handle 20: netem delay 25ms rate 32mbit
