# This generates a boxplot diagrmm of the Throughputs per 0.1s interval directly from the iperf output

set terminal pdf
set output "Throughputs_per_interval.pdf"
set title "Throughputs per interval"
set ylabel "Mbit/s"
unset xlabel

set style fill solid 0.5 border -1
set style data boxplot
set style boxplot nooutliers
#set boxwidth  0.5

plot '<grep -v -e "^\[SUM\]" -e "0\.0000-[1-9][0-9]"  afmt_noqueue_drop/iperf_tentry.log |  grep -P -o "( \d+\.\d+)(?= Mbits/sec )"' using (0.5):($1) title 'afmt\_noqueue\_drop' \
, '<grep -v -e "^\[SUM\]" -e "0\.0000-[1-9][0-9]"  afmt_fl/iperf_tentry.log |  grep -P -o "( \d+\.\d+)(?= Mbits/sec )"' using (1.5):($1) title 'afmt\_fl'\
, '<grep -v -e "^\[SUM\]" -e "0\.0000-[1-9][0-9]"  otias_sock_drop/iperf_tentry.log |  grep -P -o "( \d+\.\d+)(?= Mbits/sec )"' using (2.5):($1) title 'otias\_sock\_drop' \
, '<grep -v -e "^\[SUM\]" -e "0\.0000-[1-9][0-9]"  srtt_min_busy_wait/iperf_tentry.log |  grep -P -o "( \d+\.\d+)(?= Mbits/sec )"' using (3.5):($1) title 'srtt\_min\_busy\_wait' \
, '<grep -v -e "^\[SUM\]" -e "0\.0000-[1-9][0-9]"  afmt_noqueue_busy_wait/iperf_tentry.log |  grep -P -o "( \d+\.\d+)(?= Mbits/sec )"' using (4.5):($1) title 'afmt\_noqueue\_busy\_wait' \
, '<grep -v -e "^\[SUM\]" -e "0\.0000-[1-9][0-9]"  llfmt_noqueue_busy_wait/iperf_tentry.log |  grep -P -o "( \d+\.\d+)(?= Mbits/sec )"' using (5.5):($1) title 'llfmt\_noqueue\_busy\_wait'





# $0 is the data record number (usually same as line number in data file)
# : seperates the fields
# 1 here stands for column 1, in () it would be $1
