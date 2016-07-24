# Reinhard-VPN

A Multi-Hop link Aggregation VPN System. 

## Properties 

 * The client uses several internet uplinks to connect the server, for increased throughput and connection stability
 * Runs in Userspace, like OpenVPN
 * Currently Linux only
 * the ```vpn_client_and_server.pl``` program acts as client and server in one, depending on the configuration file

## Installation

### On client
```bash
git clone https://github.com/richi235/Reinhard-VPN

# installing the required perl modules:
cpan POE::Wheel::UDP IO::Interface::Simple POE::XS::Loop::Poll

# copy the config
cp dynIpClient.example.cfg /etc/multivpn.cfg
```
Edit the config conforming to your network setup.

### On server 
```bash
git clone https://github.com/richi235/Reinhard-VPN

# installing the required perl modules:
cpan POE::Wheel::UDP IO::Interface::Simple POE::XS::Loop::Poll

# copy the config
cp serverStaticIP.example.cfg /etc/multivpn.cfg
```
Edit the config conforming to your network setup.

## About the fork
This is a fork of multipath-vpn. Main differences include:
  * Improved throughput performance (about 23% higher throughput for a given CPU, see [Reinhard-VPN/Benchmarks/performance-bench-kvm-test-network/](Reinhard-VPN/Benchmarks/performance-bench-kvm-test-network/
) for benchmarks.)
  * Reduction and better control of Packet Reordering
  * Improved Code Quality and Documentation coverage

## Naming
This Software is named after *Reinhard von Lohengram* from Ginga Eiyuu Densetsu.
