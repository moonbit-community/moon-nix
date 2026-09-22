// Compiler-specific cache metadata, NAR classification and batch materialization.
// These are implementation details of moon, not part of the published unix API.
typedef int moon_os_ifndef_tu_marker;
#ifndef _WIN32
#define _GNU_SOURCE
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <pthread.h>
#include <dirent.h>
#include <errno.h>
extern uint8_t *moonbit_make_bytes(int32_t size, int value);

static uint8_t *mb_empty(void) { return moonbit_make_bytes(0, 0); }

static uint8_t *mb_from(const void *src, size_t len) {
  uint8_t *out = moonbit_make_bytes((int32_t)len, 0);
  if (len > 0) memcpy(out, src, len);
  return out;
}

// ── a small growable byte buffer (malloc/realloc-backed) ──────────────────────
typedef struct { uint8_t *p; size_t len; size_t cap; } Buf;

static int buf_reserve(Buf *b, size_t extra) {
  if (extra > INT32_MAX || b->len > INT32_MAX - extra) { errno = EOVERFLOW; return -1; }
  if (b->len + extra <= b->cap) return 0;
  size_t nc = b->cap ? b->cap * 2 : 4096;
  while (nc < b->len + extra) nc *= 2;
  uint8_t *np = (uint8_t *)realloc(b->p, nc);
  if (!np) return -1;
  b->p = np;
  b->cap = nc;
  return 0;
}

static int64_t timestamp_ns(int64_t sec, int64_t ns) {
  if (sec > 9223372036LL || (sec == 9223372036LL && ns > 854775807LL) ||
      sec < -9223372037LL || (sec == -9223372037LL && ns < 145224192LL))
    return -1;
  return sec >= 0 ? sec * 1000000000LL + ns
                  : (sec + 1) * 1000000000LL - (1000000000LL - ns);
}

void moon_os_stat(const uint8_t *path, int64_t *out) {
  struct stat st;
  if (stat((const char *)path, &st) != 0) { out[0] = -1; out[1] = -1; return; }
#if defined(__APPLE__)
  out[0] = timestamp_ns(st.st_mtimespec.tv_sec, st.st_mtimespec.tv_nsec);
#else
  out[0] = timestamp_ns(st.st_mtim.tv_sec, st.st_mtim.tv_nsec);
#endif
  out[1] = (int64_t)st.st_size;
}

int32_t moon_os_path_kind(const uint8_t *path) {
  struct stat st;
  if (lstat((const char *)path, &st) != 0) return 0;
  if (S_ISLNK(st.st_mode)) return 4;
  if (S_ISDIR(st.st_mode)) return 3;
  if (S_ISREG(st.st_mode)) return (st.st_mode & 0100) ? 2 : 1;
  return 0;
}

typedef struct {
  const char **srcs;
  const char **dsts;
  uint8_t *ok;
  int32_t pairs;
  int32_t next;
  pthread_mutex_t mu;
} HardlinkMany;

static void *hardlink_many_worker(void *arg) {
  HardlinkMany *h = (HardlinkMany *)arg;
  for (;;) {
    pthread_mutex_lock(&h->mu);
    int32_t i = h->next++;
    pthread_mutex_unlock(&h->mu);
    if (i >= h->pairs) break;
    unlink(h->dsts[i]);
    h->ok[i] = link(h->srcs[i], h->dsts[i]) == 0 ? 1 : 0;
  }
  return NULL;
}

uint8_t *moon_os_hardlink_many(const uint8_t *blob, int32_t pairs, int32_t parallel) {
  if (pairs <= 0) return moonbit_make_bytes(0, 0);
  uint8_t *out = moonbit_make_bytes(pairs, 0);
  const char **srcs = (const char **)malloc((size_t)pairs * sizeof(char *));
  const char **dsts = (const char **)malloc((size_t)pairs * sizeof(char *));
  if (!srcs || !dsts) {
    free(srcs);
    free(dsts);
    return out;
  }
  const char *p = (const char *)blob;
  for (int32_t i = 0; i < pairs; i++) {
    srcs[i] = p;
    p += strlen(p) + 1;
    dsts[i] = p;
    p += strlen(p) + 1;
  }
  int32_t n = parallel;
  if (n < 1) n = 1;
  if (n > pairs) n = pairs;
  if (n > 64) n = 64;
  if (n == 1) {
    for (int32_t i = 0; i < pairs; i++) {
      unlink(dsts[i]);
      out[i] = link(srcs[i], dsts[i]) == 0 ? 1 : 0;
    }
    free(srcs);
    free(dsts);
    return out;
  }
  pthread_t *threads = (pthread_t *)malloc((size_t)n * sizeof(pthread_t));
  if (!threads) {
    for (int32_t i = 0; i < pairs; i++) {
      unlink(dsts[i]);
      out[i] = link(srcs[i], dsts[i]) == 0 ? 1 : 0;
    }
    free(srcs);
    free(dsts);
    return out;
  }
  HardlinkMany h = {
    .srcs = srcs,
    .dsts = dsts,
    .ok = out,
    .pairs = pairs,
    .next = 0,
    .mu = PTHREAD_MUTEX_INITIALIZER,
  };
  int32_t started = 0;
  for (; started < n; started++) {
    if (pthread_create(&threads[started], NULL, hardlink_many_worker, &h) != 0) {
      break;
    }
  }
  if (started == 0) {
    for (int32_t i = 0; i < pairs; i++) {
      unlink(dsts[i]);
      out[i] = link(srcs[i], dsts[i]) == 0 ? 1 : 0;
    }
  }
  for (int32_t i = 0; i < started; i++) {
    pthread_join(threads[i], NULL);
  }
  pthread_mutex_destroy(&h.mu);
  free(threads);
  free(srcs);
  free(dsts);
  return out;
}

// Each entry is <kind><name>\0. POSIX follows links; Windows uses entry attributes.
uint8_t *moon_os_list_dir(const uint8_t *path, int32_t *status) {
  status[0] = 0;
  DIR *d = opendir((const char *)path);
  if (!d) { status[0] = errno; return mb_empty(); }
  size_t plen = strlen((const char *)path);
  Buf b = {0};
  struct dirent *e;
  for (;;) {
    errno = 0;
    e = readdir(d);
    if (!e) {
      if (errno != 0) status[0] = errno;
      break;
    }
    if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
    char t = 'o';
    size_t nlen = strlen(e->d_name);
    char *full = (char *)malloc(plen + 1 + nlen + 1);
    if (!full) { status[0] = errno; break; }
    memcpy(full, path, plen);
    full[plen] = '/';
    memcpy(full + plen + 1, e->d_name, nlen + 1);
    struct stat st;
    if (stat(full, &st) == 0) {
      if (S_ISDIR(st.st_mode)) t = 'd';
      else if (S_ISREG(st.st_mode)) t = 'f';
    }
    free(full);
    if (buf_reserve(&b, nlen + 2)) { status[0] = errno; break; }
    b.p[b.len++] = (uint8_t)t;
    memcpy(b.p + b.len, e->d_name, nlen);
    b.len += nlen;
    b.p[b.len++] = '\0';
  }
  if (closedir(d) != 0 && status[0] == 0) status[0] = errno;
  uint8_t *out = status[0] ? mb_empty() : mb_from(b.p, b.len);
  free(b.p);
  return out;
}

#endif
