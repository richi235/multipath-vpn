# This generates a boxplot digrmm of the RTTs directly from the iperf output

set terminal pdf
set output "SRTTs.pdf"
set title "SRTTs"
set ylabel "ms"
unset xlabel

set style fill solid 0.5 border -1
set style data boxplot
set style boxplot nooutliers
#set boxwidth  0.5

plot '<grep -P -o "(?<=K/)(\d*)(?= us )" afmt_noqueue_drop/iperf_tentry.log' using (0.5):($1/1000) title 'afmt\_noqueue\_drop' \
, '<grep -P -o "(?<=K/)(\d*)(?= us )" afmt_fl/iperf_tentry.log' using (1.5):($1/1000) title 'afmt\_fl'\
, '<grep -P -o "(?<=K/)(\d*)(?= us )" otias_sock_drop/iperf_tentry.log' using (2.5):($1/1000) title 'otias\_sock\_drop' \
, '<grep -P -o "(?<=K/)(\d*)(?= us )" srtt_min_busy_wait/iperf_tentry.log' using (3.5):($1/1000) title 'srtt\_min\_busy\_wait' \
, '<grep -P -o "(?<=K/)(\d*)(?= us )" afmt_noqueue_busy_wait/iperf_tentry.log' using (4.5):($1/1000) title 'afmt\_noqueue\_busy\_wait' \
, '<grep -P -o "(?<=K/)(\d*)(?= us )" llfmt_noqueue_busy_wait/iperf_tentry.log' using (5.5):($1/1000) title 'llfmt\_noqueue\_busy\_wait'


# $0 is the data record number (usually same as line number in data file)
# : seperates the fields
# 1 here stands for column 1, in () it would be $1
