#define _GNU_SOURCE
// Minimal PSF1/PSF2 console font loader for the OpenWrt recovery initramfs.
#include <errno.h>
#include <fcntl.h>
#include <linux/kd.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <unistd.h>

#define PSF1_MAGIC0 0x36
#define PSF1_MAGIC1 0x04
#define PSF1_MODE512 0x01
#define PSF2_MAGIC 0x864ab572U

struct font {
  unsigned int width;
  unsigned int height;
  unsigned int charcount;
  unsigned char *data;
};

static uint32_t le32(const unsigned char *p) {
  return ((uint32_t)p[0]) | ((uint32_t)p[1] << 8) |
         ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static int read_file(const char *path, unsigned char **buf, size_t *len) {
  int fd;
  struct stat st;
  ssize_t n;
  size_t off;

  fd = open(path, O_RDONLY);
  if (fd < 0) {
    perror(path);
    return -1;
  }
  if (fstat(fd, &st) != 0 || st.st_size <= 0) {
    perror(path);
    close(fd);
    return -1;
  }
  *len = (size_t)st.st_size;
  *buf = malloc(*len);
  if (!*buf) {
    perror("malloc");
    close(fd);
    return -1;
  }
  off = 0;
  while (off < *len) {
    n = read(fd, *buf + off, *len - off);
    if (n < 0) {
      if (errno == EINTR)
        continue;
      perror(path);
      close(fd);
      return -1;
    }
    if (n == 0)
      break;
    off += (size_t)n;
  }
  close(fd);
  if (off != *len) {
    fprintf(stderr, "%s: short read\n", path);
    return -1;
  }
  return 0;
}

static int parse_psf(unsigned char *buf, size_t len, struct font *font) {
  unsigned int header_size, glyph_size, needed;

  memset(font, 0, sizeof(*font));

  if (len >= 4 && buf[0] == PSF1_MAGIC0 && buf[1] == PSF1_MAGIC1) {
    font->width = 8;
    font->height = buf[3];
    font->charcount = (buf[2] & PSF1_MODE512) ? 512 : 256;
    glyph_size = font->height;
    header_size = 4;
  } else if (len >= 32 && le32(buf) == PSF2_MAGIC) {
    header_size = le32(buf + 8);
    font->charcount = le32(buf + 16);
    glyph_size = le32(buf + 20);
    font->height = le32(buf + 24);
    font->width = le32(buf + 28);
  } else {
    fprintf(stderr, "unsupported font format\n");
    return -1;
  }

  if (font->width == 0 || font->height == 0 || font->height > 64 ||
      font->charcount == 0 || glyph_size == 0 || header_size >= len) {
    fprintf(stderr, "invalid font metadata\n");
    return -1;
  }

  needed = header_size + glyph_size * font->charcount;
  if ((size_t)needed > len) {
    fprintf(stderr, "truncated font glyph data\n");
    return -1;
  }

  font->data = buf + header_size;
  return 0;
}

static int open_console(const char *path) {
  static const char *fallbacks[] = {"/dev/tty0", "/dev/tty1", "/dev/console"};
  size_t i;
  int fd;

  if (path) {
    fd = open(path, O_RDWR | O_CLOEXEC);
    if (fd >= 0)
      return fd;
    perror(path);
    return -1;
  }

  if (isatty(STDIN_FILENO))
    return STDIN_FILENO;

  for (i = 0; i < sizeof(fallbacks) / sizeof(fallbacks[0]); i++) {
    fd = open(fallbacks[i], O_RDWR | O_CLOEXEC);
    if (fd >= 0)
      return fd;
  }

  perror("open console");
  return -1;
}

static int set_font(int fd, const struct font *font) {
  struct console_font_op op;

  memset(&op, 0, sizeof(op));
  op.op = KD_FONT_OP_SET_TALL;
  op.width = font->width;
  op.height = font->height;
  op.charcount = font->charcount;
  op.data = font->data;

  if (ioctl(fd, KDFONTOP, &op) == 0)
    return 0;

  op.op = KD_FONT_OP_SET;
  if (ioctl(fd, KDFONTOP, &op) == 0)
    return 0;

  perror("KDFONTOP");
  return -1;
}

static void usage(const char *argv0) {
  fprintf(stderr, "usage: %s [-C /dev/ttyN] FONT.psf\n", argv0);
}

int main(int argc, char **argv) {
  const char *console = NULL;
  const char *font_path = NULL;
  unsigned char *buf = NULL;
  size_t len = 0;
  struct font font;
  int fd, ret;

  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "-C") == 0 && i + 1 < argc) {
      console = argv[++i];
    } else if (argv[i][0] == '-') {
      usage(argv[0]);
      return 2;
    } else if (!font_path) {
      font_path = argv[i];
    } else {
      usage(argv[0]);
      return 2;
    }
  }

  if (!font_path) {
    usage(argv[0]);
    return 2;
  }

  if (read_file(font_path, &buf, &len) != 0)
    return 1;
  if (parse_psf(buf, len, &font) != 0) {
    free(buf);
    return 1;
  }

  fd = open_console(console);
  if (fd < 0) {
    free(buf);
    return 1;
  }

  ret = set_font(fd, &font);
  if (fd != STDIN_FILENO)
    close(fd);
  free(buf);
  return ret == 0 ? 0 : 1;
}
