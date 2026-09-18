/*
 * bin/bash replacement (see the "Musl-host bash fix" block in
 * Launcher/build-appimage.sh). Built -static: the kernel runs it directly
 * with zero library loading, so a poisoned LD_PRELOAD (inherited from the
 * setup process on every host) cannot kill it before main() - a #!/bin/sh
 * script wrapper dies there on musl hosts instead.
 *
 * What it does, in order:
 *   1. Scrubs LD_PRELOAD and LD_LIBRARY_PATH from its own environ. Both are
 *      poison for host-musl children (glibc .so's shadow musl's and musl
 *      aborts loading them); nothing bundled needs them because the loader
 *      below gets an explicit --library-path (identical resolution to a
 *      sharun dispatch on glibc hosts).
 *   2. Resolves its own image dir, preferring the unfakeable
 *      /proc/self/exe, then $0's directory, then $APPDIR as a last resort.
 *   3. execv()s the bundled loader with the real bash, passing argv[0] as
 *      the real path - exactly what the dynamic loader would set, so $BASH
 *      matches loader-direct runs.
 *
 * Deliberately dependency-free (no NSS, no malloc in the hot path) so
 * -static stays clean. Linux-only (like every AppImage).
 */
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifndef SHARUN_LDNAME
#error "SHARUN_LDNAME must come from the build (the deployed loader file name)"
#endif
#ifndef BASH_REAL
#error "BASH_REAL must come from the build (real bash file name under shared/bin/)"
#endif

/* Truncate buf in place to its parent directory (no-op if none). */
static void dir_up(char *buf)
{
    size_t n = strlen(buf);
    while (n > 0 && buf[n - 1] != '/')
        n--;
    while (n > 1 && buf[n - 2] == '/')
        n--;
    if (n <= 1) {
        buf[0] = (buf[0] == '/') ? '/' : '.';
        buf[1] = '\0';
        return;
    }
    buf[n - 1] = '\0';
}

int main(int argc, char **argv)
{
    static char imgdir[PATH_MAX];
    static char loader[PATH_MAX];
    static char bashreal[PATH_MAX];
    static char libdir[PATH_MAX];
    ssize_t len;

    (void)argc;

    /* 1. The poison must go before anything dynamic could ever load. */
    unsetenv("LD_PRELOAD");
    unsetenv("LD_LIBRARY_PATH");

    /* 2a. Preferred: /proc/self/exe cannot lie (argv[0] and $APPDIR can). */
    imgdir[0] = '\0';
    len = readlink("/proc/self/exe", imgdir, sizeof(imgdir) - 1);
    if (len > 0 && (size_t)len < sizeof(imgdir) - 1) {
        imgdir[len] = '\0';
        dir_up(imgdir); /* .../bin/bash -> .../bin */
        dir_up(imgdir); /* .../bin -> ... (image dir) */
    } else {
        imgdir[0] = '\0';
    }

    /* 2b. Fallback: $0 when it carries a directory. */
    if (imgdir[0] == '\0' && argv[0] != NULL && strchr(argv[0], '/') != NULL) {
        snprintf(imgdir, sizeof(imgdir), "%s", argv[0]);
        dir_up(imgdir);
        dir_up(imgdir);
    }

    /* 2c. Last resort: $APPDIR (correct in normal image runs, wrong when a
       nested packager re-exports it - hence last, never first). */
    if (imgdir[0] == '\0' || imgdir[0] == '.' ) {
        const char *env = getenv("APPDIR");
        if (env != NULL && env[0] != '\0')
            snprintf(imgdir, sizeof(imgdir), "%s", env);
    }
    if (imgdir[0] == '\0' || imgdir[0] == '.') {
        dprintf(STDERR_FILENO, "bash wrapper: cannot locate image dir\n");
        _exit(127);
    }

    if (strlen(imgdir) + 64 >= sizeof(imgdir)) {
        dprintf(STDERR_FILENO, "bash wrapper: image path too long\n");
        _exit(127);
    }
    snprintf(loader, sizeof(loader), "%s/lib/%s", imgdir, SHARUN_LDNAME);
    snprintf(libdir, sizeof(libdir), "%s/lib", imgdir);
    snprintf(bashreal, sizeof(bashreal), "%s/shared/bin/%s", imgdir, BASH_REAL);
    if (access(loader, X_OK) != 0 || access(bashreal, R_OK) != 0) {
        dprintf(STDERR_FILENO, "bash wrapper: bad image dir %s\n", imgdir);
        _exit(127);
    }

    /* 3. New argv: loader, --library-path, lib, real-bash-as-argv0, then the
       caller's args verbatim. argv[0] = real path, exactly like a
       loader-direct launch (keeps $BASH identical to one). */
    {
        static char *v[4100];
        int n, j;
        for (n = 0; argv[n] != NULL; n++)
            ;
        if (n + 4 >= 4100) {
            dprintf(STDERR_FILENO, "bash wrapper: too many args\n");
            _exit(127);
        }
        v[0] = loader;
        v[1] = (char *)"--library-path";
        v[2] = libdir;
        for (j = 0; j <= n; j++)
            v[3 + j] = (j == 0) ? bashreal : argv[j];
        execv(loader, v);
        dprintf(STDERR_FILENO, "bash wrapper: cannot exec %s\n", loader);
        _exit(127);
    }
}
