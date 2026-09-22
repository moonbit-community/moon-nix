// Compiler-specific cache metadata, NAR classification and batch materialization.
// These are implementation details of moon, not part of the published unix API.
typedef int moon_os_ifdef_tu_marker;
#ifdef _WIN32
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>
extern uint8_t *moonbit_make_bytes(int32_t size, int value);

static uint8_t *mb_empty(void) { return moonbit_make_bytes(0, 0); }

static uint8_t *mb_from(const void *src, size_t len) {
  uint8_t *out = moonbit_make_bytes((int32_t)len, 0);
  if (len > 0) memcpy(out, src, len);
  return out;
}

typedef struct { uint8_t *p; size_t len; size_t cap; } Buf;
static int buf_reserve(Buf *b, size_t extra) {
  if (extra > INT32_MAX || b->len > INT32_MAX - extra) return ERROR_BUFFER_OVERFLOW;
  if (b->len + extra <= b->cap) return 0;
  size_t nc = b->cap ? b->cap * 2 : 4096;
  while (nc < b->len + extra) nc *= 2;
  uint8_t *np = (uint8_t *)realloc(b->p, nc);
  if (!np) return ERROR_NOT_ENOUGH_MEMORY;
  b->p = np;
  b->cap = nc;
  return 0;
}

static wchar_t *to_wide(const uint8_t *s) {
  int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, (const char *)s, -1, NULL, 0);
  if (n <= 0) return NULL;
  wchar_t *w = (wchar_t *)malloc((size_t)n * sizeof(wchar_t));
  if (!w) { SetLastError(ERROR_NOT_ENOUGH_MEMORY); return NULL; }
  if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, (const char *)s, -1, w, n)) {
    DWORD error = GetLastError(); free(w); SetLastError(error); return NULL;
  }
  return w;
}

static void filetime_to_unix_time(const FILETIME *ft, int64_t *out) {
  ULARGE_INTEGER u;
  u.LowPart = ft->dwLowDateTime;
  u.HighPart = ft->dwHighDateTime;
  out[0] = (int64_t)(u.QuadPart / 10000000ULL) - 11644473600LL;
  out[1] = (int64_t)(u.QuadPart % 10000000ULL) * 100LL;
}

static int stat_attrs(const uint8_t *path, WIN32_FILE_ATTRIBUTE_DATA *fad) {
  wchar_t *w = to_wide(path);
  if (!w) return -1;
  int ok = GetFileAttributesExW(w, GetFileExInfoStandard, fad) ? 0 : -1;
  free(w);
  return ok;
}

void moon_os_stat(const uint8_t *path, int64_t *out) {
  WIN32_FILE_ATTRIBUTE_DATA fad;
  if (stat_attrs(path, &fad) != 0) { out[0] = -1; out[1] = -1; return; }
  int64_t time[2];
  filetime_to_unix_time(&fad.ftLastWriteTime, time);
  if (time[0] > 9223372036LL || (time[0] == 9223372036LL && time[1] > 854775807LL) ||
      time[0] < -9223372037LL || (time[0] == -9223372037LL && time[1] < 145224192LL)) {
    out[0] = -1;
  } else {
    out[0] = time[0] >= 0 ? time[0] * 1000000000LL + time[1]
                         : (time[0] + 1) * 1000000000LL - (1000000000LL - time[1]);
  }
  out[1] = (int64_t)(((uint64_t)fad.nFileSizeHigh << 32) | fad.nFileSizeLow);
}

int32_t moon_os_path_kind(const uint8_t *path) {
  wchar_t *w = to_wide(path);
  if (!w) return 0;
  DWORD attr = GetFileAttributesW(w);
  free(w);
  if (attr == INVALID_FILE_ATTRIBUTES) return 0;
  if (attr & FILE_ATTRIBUTE_REPARSE_POINT) return 4;
  if (attr & FILE_ATTRIBUTE_DIRECTORY) return 3;
  return 1;
}

static int32_t compiler_hardlink(const uint8_t *src, const uint8_t *dst) {
  wchar_t *wsrc = to_wide(src);
  wchar_t *wdst = to_wide(dst);
  if (!wsrc || !wdst) {
    if (wsrc) free(wsrc);
    if (wdst) free(wdst);
    return -1;
  }
  DeleteFileW(wdst);
  int rc = CreateHardLinkW(wdst, wsrc, NULL) ? 0 : -1;
  free(wsrc);
  free(wdst);
  return rc;
}

typedef struct {
  const uint8_t **srcs;
  const uint8_t **dsts;
  uint8_t *ok;
  int32_t pairs;
  volatile LONG next;
} HardlinkMany;

static DWORD WINAPI hardlink_many_worker(LPVOID arg) {
  HardlinkMany *h = (HardlinkMany *)arg;
  for (;;) {
    LONG i = InterlockedIncrement(&h->next) - 1;
    if (i >= h->pairs) break;
    h->ok[i] = compiler_hardlink(h->srcs[i], h->dsts[i]) == 0 ? 1 : 0;
  }
  return 0;
}

uint8_t *moon_os_hardlink_many(const uint8_t *blob, int32_t pairs, int32_t parallel) {
  if (pairs <= 0) return moonbit_make_bytes(0, 0);
  uint8_t *out = moonbit_make_bytes(pairs, 0);
  const uint8_t **srcs = (const uint8_t **)malloc((size_t)pairs * sizeof(uint8_t *));
  const uint8_t **dsts = (const uint8_t **)malloc((size_t)pairs * sizeof(uint8_t *));
  if (!srcs || !dsts) {
    free(srcs);
    free(dsts);
    return out;
  }
  const uint8_t *p = blob;
  for (int32_t i = 0; i < pairs; i++) {
    srcs[i] = p;
    p += strlen((const char *)p) + 1;
    dsts[i] = p;
    p += strlen((const char *)p) + 1;
  }
  int32_t n = parallel;
  if (n < 1) n = 1;
  if (n > pairs) n = pairs;
  if (n > 64) n = 64;
  if (n == 1) {
    for (int32_t i = 0; i < pairs; i++) {
      out[i] = compiler_hardlink(srcs[i], dsts[i]) == 0 ? 1 : 0;
    }
    free(srcs);
    free(dsts);
    return out;
  }
  HANDLE *threads = (HANDLE *)malloc((size_t)n * sizeof(HANDLE));
  if (!threads) {
    for (int32_t i = 0; i < pairs; i++) {
      out[i] = compiler_hardlink(srcs[i], dsts[i]) == 0 ? 1 : 0;
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
  };
  DWORD started = 0;
  for (; started < (DWORD)n; started++) {
    threads[started] = CreateThread(NULL, 0, hardlink_many_worker, &h, 0, NULL);
    if (!threads[started]) break;
  }
  if (started == 0) {
    for (int32_t i = 0; i < pairs; i++) {
      out[i] = compiler_hardlink(srcs[i], dsts[i]) == 0 ? 1 : 0;
    }
  }
  if (started > 0) {
    WaitForMultipleObjects(started, threads, TRUE, INFINITE);
    for (DWORD i = 0; i < started; i++) {
      CloseHandle(threads[i]);
    }
  }
  free(threads);
  free(srcs);
  free(dsts);
  return out;
}

// Each entry is <kind><name>\0. POSIX follows links; Windows uses entry attributes.
uint8_t *moon_os_list_dir(const uint8_t *path, int32_t *status) {
  status[0] = 0;
  size_t plen = strlen((const char *)path);
  uint8_t *pat = (uint8_t *)malloc(plen + 3);
  if (!pat) { status[0] = ERROR_NOT_ENOUGH_MEMORY; return mb_empty(); }
  memcpy(pat, path, plen);
  size_t cursor = plen;
  if (cursor == 0 || (pat[cursor - 1] != '/' && pat[cursor - 1] != 0x5c)) pat[cursor++] = 0x5c;
  pat[cursor++] = '*';
  pat[cursor] = '\0';
  wchar_t *wpat = to_wide(pat);
  if (!wpat) status[0] = (int32_t)GetLastError();
  free(pat);
  if (status[0]) return mb_empty();
  WIN32_FIND_DATAW fd;
  HANDLE h = FindFirstFileW(wpat, &fd);
  if (h == INVALID_HANDLE_VALUE) status[0] = (int32_t)GetLastError();
  free(wpat);
  if (status[0]) return mb_empty();
  Buf b = {0};
  do {
    if (!wcscmp(fd.cFileName, L".") || !wcscmp(fd.cFileName, L"..")) continue;
    char t = (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) ? 'd' : 'f';
    int count = WideCharToMultiByte(CP_UTF8, 0, fd.cFileName, -1, NULL, 0, NULL, NULL);
    if (count <= 0) { status[0] = (int32_t)GetLastError(); break; }
    size_t nlen = (size_t)count - 1;
    status[0] = buf_reserve(&b, nlen + 2);
    if (status[0]) break;
    b.p[b.len++] = (uint8_t)t;
    if (!WideCharToMultiByte(CP_UTF8, 0, fd.cFileName, -1,
                             (char *)b.p + b.len, count, NULL, NULL)) {
      status[0] = (int32_t)GetLastError();
      break;
    }
    b.len += (size_t)count;
  } while (FindNextFileW(h, &fd));
  if (status[0] == 0 && GetLastError() != ERROR_NO_MORE_FILES) status[0] = (int32_t)GetLastError();
  if (!FindClose(h) && status[0] == 0) status[0] = (int32_t)GetLastError();
  uint8_t *out = status[0] ? mb_empty() : mb_from(b.p, b.len);
  free(b.p);
  return out;
}

#endif
