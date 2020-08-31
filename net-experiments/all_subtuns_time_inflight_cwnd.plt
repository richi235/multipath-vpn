set terminal pdf size 5,5
set output "all_subtuns_time_inflight_cwnd.pdf"
# set xlabel "Seconds"
set ylabel "Packets"

#set size 1,1
#set origin 0,0
set multiplot layout 3,1

#set title "Subtun 0"
plot "subtun0_time_inflight_cwnd_srtt.tsv" using 1:3 with lines title "packets in flight", \
"subtun0_time_inflight_cwnd_srtt.tsv" using 1:4 with lines title "cwnd"

#set title "Subtun 1"
plot "subtun1_time_inflight_cwnd_srtt.tsv" using 1:3 with lines title "packets in flight", \
"subtun1_time_inflight_cwnd_srtt.tsv" using 1:4 with lines title "cwnd"

#set title "Subtun 2"
plot "subtun2_time_inflight_cwnd_srtt.tsv" using 1:3 with lines title "packets in flight", \
"subtun2_time_inflight_cwnd_srtt.tsv" using 1:4 with lines title "cwnd"

unset multiplot

# $0 is the data record number (usually same as line number in data file)
# : seperates the fields
# 1 here stands for column 1, in () it would be $1
