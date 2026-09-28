/* shim for the freestanding Dhrystone build (tb/perf/dhry/build.sh) */
struct tms { long tms_utime, tms_stime, tms_cutime, tms_cstime; };
