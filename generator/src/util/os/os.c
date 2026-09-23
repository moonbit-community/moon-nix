// Directory enumeration for package discovery.
typedef int moon_os_ifndef_tu_marker;
#ifndef _WIN32
#define _GNU_SOURCE
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
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
