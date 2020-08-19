set terminal pdf
set output "afmt_pdv.pdf"
set title "Packet Delay Variation"
set xlabel "Packet Number"
set ylabel "delay difference (Seconds)"

# set key outside center below
# set datafile missing "-nan"

plot "delay_variations" index 0 title "Delay deltas" with dots
