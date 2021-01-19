# This generates boxplot diagramms of the RTTs directly from the iperf output files
set terminal pdf
set output "SRTTs_publication.pdf"
set title "SRTTs"
set ylabel "ms"
unset xlabel

set key off

set style fill solid 0.8 border lt -1
set style data boxplot
set style boxplot nooutliers
set style boxplot fraction 0.8
#set boxwidth  0.5

# Warmup phase: calculate the number of rls(record lines) at the start to ignore
warmup_seconds=10
iperf_report_interval=1
flowcount=4
rls_to_ignore = (warmup_seconds/iperf_report_interval) * flowcount

plot '<grep -P -o "(?<=K/)(\d*)(?= us )" otias_sock_drop/iperf_tentry.log' skip rls_to_ignore using (0.0):(column(1)/1000):(0):('OTIAS') \
, '<grep -P -o "(?<=K/)(\d*)(?= us )" srtt_min_busy_wait/iperf_tentry.log' skip rls_to_ignore using (1.0):(column(1)/1000):(0):('LowRTT') \
, '<grep -P -o "(?<=K/)(\d*)(?= us )" afmt_noqueue_drop/iperf_tentry.log' skip rls_to_ignore using (2.0):(column(1)/1000):(0):('HTMT\\_drop') \
, '<grep -P -o "(?<=K/)(\d*)(?= us )" afmt_fl/iperf_tentry.log' skip rls_to_ignore using (3.0):(column(1)/1000):(0):('AFMT') \
, '<grep -P -o "(?<=K/)(\d*)(?= us )" afmt_noqueue_busy_wait/iperf_tentry.log' skip rls_to_ignore using (4.0):(column(1)/1000):(0):('HTMT\\_wait') 

# about: (0.5):(column(1)/1000)
# the 0.5 is the x value where this boxplot box will be placed
# column(1) is the column of the data file used , 0 would be the record number

