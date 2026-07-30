On a little macbook air M2

Workload: GET /   connections=50   duration=10s   warmup=3s
Hardware counters: unavailable (Darwin; needs Linux + perf)

Metric                                   Go              Zig             zig2         zig2-zio
-------------------------- ---------------- ---------------- ---------------- ----------------
Requests                             146879           557746           436634           457910
RPS (req/s)                           14684            13943            43652            45787
Latency avg (ms)                       3.36             0.50             1.03             0.98
Latency p90 (ms)                       4.08             0.99             2.31             1.99
Latency p99 (ms)                       5.82             2.92             8.79             5.63
CPU avg (% of 1 core)                   185               21              112              118
Mem avg (MiB)                          24.6             11.6              7.6              7.1
Mem max (MiB)                          24.7             11.6              7.6              7.1
