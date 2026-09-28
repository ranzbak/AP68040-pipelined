/* shim for the freestanding Dhrystone build (tb/perf/dhry/build.sh) */
char *strcpy(char *d, const char *s);
int strcmp(const char *a, const char *b);
void *memcpy(void *d, const void *s, unsigned long n);
void *memset(void *d, int c, unsigned long n);
