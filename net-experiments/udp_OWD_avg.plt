
set terminal pdfcairo # mono
set output "owd_avg.pdf"
set title "Average One Way Delay per flow"
set ylabel "ms"
unset xlabel

set style fill solid 
set style data boxes
set boxwidth  0.5
unset key

plot  "otias_sock_drop/udp_aggregates.tsv"          using  (1.0):(column(3)):xtic("OTIAS")  \
,     "afmt_fl/udp_aggregates.tsv"                  using  (1.75):(column(3)):xtic("AFMT")   \
,     "srtt_min_busy_wait/udp_aggregates.tsv"       using  (2.5):(column(3)):xtic("LowRTT") \
,     "llfmt_noqueue_busy_wait/udp_aggregates.tsv"  using  (3.25):(column(3)):xtic("LLMT")   \
,     "" 					    using  (0.5):2:(0)  \
,     "" 					    using  (3.75):2:(0)  \
