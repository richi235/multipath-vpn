#!/bin/bash

# this runs until the sender gets interupted by SIGINT and closes the connection
nc -v -v -l -p 1337 > /dev/null 2> /tmp/nc-stats


