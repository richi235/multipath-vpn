#!/bin/bash

nc 172.31.255.88 1337 < /dev/zero &

sleep 120
kill $(jobs -p)

exit
