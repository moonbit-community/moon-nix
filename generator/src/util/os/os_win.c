// Directory enumeration for package discovery.
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
