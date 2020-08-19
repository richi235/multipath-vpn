set terminal pdf
set output "Throughput.pdf"
set title "Throughput"
set xlabel "Number"
set ylabel "Bits per second"

# set key outside center below
# set datafile missing "-nan"

plot "server_bps" title "Throughput" with lines
