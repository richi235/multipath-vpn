Reinhard-VPN
=============

A tunneling VPN client and server, which supports failover and multiple connections via the linux tuntap interface.


## Install

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
