set terminal pdf
set output "Throughput.pdf"
set title "Throughput"
set xlabel "Seconds"
set ylabel "Bits per second"

set datafile separator ","
# set key outside center below
# set datafile missing "-nan"

plot "iperf_server_output.csv" using ($0/10):9 title "Throughput" with lines

# $0 is the data record number (usually same as line number in data file)
# : seperates the fields
# 1 here stands for column 1, in () it would be $1
