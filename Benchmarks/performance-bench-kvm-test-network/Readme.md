# Throughput Benchmarks

## How where these Benchmarks measured?

In a test network I sent data from a client to a server over a Multipath-VPN/Reinhard-VPN connection.
The test took 120 seconds and the amount of data transfered in this was measured via the ```-v -v```
verbose output of netcat. Which looks like: 

```
╰─$ cat ./original-multipath-vpn/nc-stats 
listening on [any] 1337 ...
192.168.66.2: inverse host lookup failed: Unknown host
connect to [172.31.255.88] from (UNKNOWN) [192.168.66.2] 48308
 sent 0, rcvd 1461186496
```

For test automation I wrote and used the following two helper scripts: 
  * [perf-bench-sender.sh](perf-bench-sender.sh) on MTC
  * [perf-bench-receiver.sh](perf-bench-receiver.sh) on MTS
  
## Results
```
./original-multipath-vpn/nc-stats: sent 0, rcvd 1461186496
./reinhard-vpn/v3-50-50/nc-stats: sent 0, rcvd 1880673608
./reinhard-vpn/v2-50-50/nc-stats: sent 0, rcvd 1845849592
./reinhard-vpn/v1-30:30/nc-stats: sent 0, rcvd 1807243408
```

Or in a better aranged format:

 Version/configuration | Bytes transfered
-----------------------|--------------------
./original-multipath-vpn/nc-stats: | 1461186496
./reinhard-vpn/v3-50-50/nc-stats: | 1880673608
./reinhard-vpn/v2-50-50/nc-stats: | 1845849592
./reinhard-vpn/v1-30:30/nc-stats: | 1807243408

### Subdirectories
For each measurment there is a subdirectory where you can find the configurations used and the full
netcat stat output.
