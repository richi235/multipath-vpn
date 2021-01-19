# This generates a boxplot diagrmm of the Throughputs per 0.1s interval directly from the iperf output

set terminal pdfcairo # mono
set output "Throughputs_per_interval_pub.pdf"
set title "Throughputs per interval"
set ylabel "Mbit/s"
unset xlabel

# set key box
# set key left

set style fill solid 0.8 border lt -1
#set style line 1 lw 1 lc rgb "black"
#set style increment user
set style data boxplot
set style boxplot nooutliers
set style boxplot fraction 0.806
#set style boxplot  separation 0
#set boxwidth  0.5

print "Titten"

# Warmup phase: calculate the number of rls(record lines) at the start to ignore
warmup_seconds=10
iperf_report_interval=1
flowcount=4
rls_to_ignore = (warmup_seconds/iperf_report_interval) * flowcount


plot '<grep -v -e "^\[SUM\]" -e "0\.0000-[1-9][0-9]"  otias_sock_drop/iperf_tentry.log |  grep -P -o "( \d+\.\d+)(?= Mbits/sec )"' skip rls_to_ignore using (0.0):(column(1)):(0):("OTIAS") notitle \
, '<grep -v -e "^\[SUM\]" -e "0\.0000-[1-9][0-9]"  srtt_min_busy_wait/iperf_tentry.log |  grep -P -o "( \d+\.\d+)(?= Mbits/sec )"' skip rls_to_ignore using (1.0):(column(1)):(0):('LowRTT') notitle \
, '<grep -v -e "^\[SUM\]" -e "0\.0000-[1-9][0-9]"  afmt_noqueue_drop/iperf_tentry.log |  grep -P -o "( \d+\.\d+)(?= Mbits/sec )"' skip rls_to_ignore using (2.0):(column(1)):(0):('HTMT\\_drop')  notitle\
, '<grep -v -e "^\[SUM\]" -e "0\.0000-[1-9][0-9]"  afmt_fl/iperf_tentry.log |  grep -P -o "( \d+\.\d+)(?= Mbits/sec )"' skip rls_to_ignore using (3.0):(column(1)):(0):('AFMT') notitle \
, '<grep -v -e "^\[SUM\]" -e "0\.0000-[1-9][0-9]"  afmt_noqueue_busy_wait/iperf_tentry.log |  grep -P -o "( \d+\.\d+)(?= Mbits/sec )"' skip rls_to_ignore using (4.0):(column(1)):(0):('HTMT\\_wait')  notitle

