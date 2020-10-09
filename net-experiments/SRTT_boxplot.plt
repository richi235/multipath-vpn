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

plot '<grep -P -o "(?<=K/)(\d*)(?= us )" iperf_tentry.log' using (1.0):($1/1000) title "RTTs"


# $0 is the data record number (usually same as line number in data file)
# : seperates the fields
# 1 here stands for column 1, in () it would be $1
