/*
 * Copyright (c) 2026, Jesús Daniel Colmenares Oviedo <DtxdF@disroot.org>
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice, this
 *    list of conditions and the following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 *    this list of conditions and the following disclaimer in the documentation
 *    and/or other materials provided with the distribution.
 *
 * 3. Neither the name of the copyright holder nor the names of its
 *    contributors may be used to endorse or promote products derived from
 *    this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
 * CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
 * OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include <sys/stat.h>
#include <sys/param.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <archive.h>
#include <archive_entry.h>
#include <err.h>
#include <errno.h>
#include <fts.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <spawn.h>
#include <sysexits.h>
#include <unistd.h>

#ifndef _APPSCRIPT_DEFAULT_TMPDIR
#   define _APPSCRIPT_DEFAULT_TMPDIR "/var/tmp/appscript"
#endif

extern char **environ;
extern char _binary_payload_start[];
extern char _binary_payload_end[];

static char *extractdir = NULL;
static char tmpdir_tmpl[PATH_MAX];
static int ignored_signals[] = {
    SIGALRM, SIGVTALRM, SIGPROF, SIGUSR1, SIGUSR2, 0
};
static int handled_signals[] = {
    SIGHUP, SIGINT, SIGQUIT, SIGTERM, SIGXCPU, SIGXFSZ, 0
};
static volatile sig_atomic_t should_stop = 0;
static volatile pid_t child_pid = 0;

static char *whoami(void);
static void cleanup(void);
static void on_signal(int sig);
static void ignore_signals(void);
static void handle_signals(void);
static void rm_tree(char **path_argv);

int
main(int argc, char **argv)
{
    int ret, status;
    bool is_error = false;
    pid_t pid;
    const char *tmpdir, *entry_pathname;
    char *iam;
    size_t payload_size;
    struct archive *a, *ext;
    struct archive_entry *entry;
    struct stat sbuf;
    uid_t uid;
    gid_t gid;

    uid = geteuid();
    gid = getegid();
    iam = whoami();
    payload_size = _binary_payload_end - _binary_payload_start;

    ignore_signals();
    handle_signals();

    if (atexit(cleanup) != 0)
        err(EX_SOFTWARE, "atexit");

    /* This should be a mounted tmpfs(4) fs. */
    tmpdir = _APPSCRIPT_DEFAULT_TMPDIR;
    if ((ret = lstat(tmpdir, &sbuf)) == -1)
        tmpdir = "/tmp";
    if (ret == -1 && lstat(tmpdir, &sbuf) == -1)
        err(EX_SOFTWARE, "lstat(%s)", tmpdir);
    if (!S_ISDIR(sbuf.st_mode))
        err(EX_DATAERR, "%s: Not a directory", tmpdir);
    if (!(sbuf.st_mode & (S_ISVTX | S_IRWXU | S_IRWXG | S_IRWXO)))
        err(EX_NOPERM, "Operation not permitted");

    if (snprintf(tmpdir_tmpl, sizeof(tmpdir_tmpl), "%s/%s", tmpdir, "appscript_XXXXXXXXXXX") < 0)
        err(EX_SOFTWARE, "snprintf");

    if ((extractdir = mkdtemp(tmpdir_tmpl)) == NULL)
        err(EX_SOFTWARE, "mkdtemp");

    if (chdir(extractdir) == -1)
        err(EX_SOFTWARE, "chdir(%s)", extractdir);

    if ((a = archive_read_new()) == NULL || (ext = archive_write_disk_new()) == NULL) {
        errx(EX_SOFTWARE, "can't allocate more memory or something is wrong."
            "Cannot continue.");
    }

    int flags = ARCHIVE_EXTRACT_SECURE_NOABSOLUTEPATHS |
                ARCHIVE_EXTRACT_SECURE_NODOTDOT |
                ARCHIVE_EXTRACT_SECURE_SYMLINKS;

    if (archive_write_disk_set_options(ext, flags) != ARCHIVE_OK) {
        errx(EX_SOFTWARE, "archive_write_set_options (%d): %s", archive_errno(ext),
            archive_error_string(ext));
    }

    archive_read_support_filter_all(a);
    archive_read_support_format_all(a);

    if (archive_read_open_memory(a, &_binary_payload_start, payload_size) == ARCHIVE_FATAL) {
        errx(EX_SOFTWARE, "archive_read_open_memory (%d): %s", archive_errno(a),
            archive_error_string(a));
    }

    while (!should_stop) {
        ret = archive_read_next_header(a, &entry);

        if (ret == ARCHIVE_EOF)
            break;
        if (ret < ARCHIVE_OK) {
            warnx("archive_read_next_header (%d): %s", archive_errno(a),
                archive_error_string(a));
        }
        if (ret == ARCHIVE_RETRY)
            continue;
        if (ret == ARCHIVE_FATAL) {
            is_error = true;
            break;
        }

        entry_pathname = archive_entry_pathname(entry);
        if (entry_pathname == NULL || entry_pathname[0] == '\0') {
            warnx("Archive entry has empty or unreadable filename ... skipping.");
            continue;
        }

        archive_entry_set_uid(entry, uid);
        archive_entry_set_uname(entry, NULL);
        archive_entry_set_gid(entry, gid);
        archive_entry_set_gname(entry, NULL);

        ret = archive_read_extract2(a, entry, ext);

        if (ret != ARCHIVE_OK) {
            warnx("archive_read_extract2(%s) (%d): %s", entry_pathname,
                archive_errno(ext), archive_error_string(ext));
        }
        if (ret == ARCHIVE_FATAL) {
            is_error = true;
            break;
        }
    }

    if (archive_read_close(a) != ARCHIVE_OK) {
        warnx("archive_read_close (%d): %s", archive_errno(a),
            archive_error_string(a));
    }
    archive_read_free(a);

    if (archive_write_close(ext) != ARCHIVE_OK) {
        warnx("archive_write_close (%d): %s", archive_errno(ext),
            archive_error_string(ext));
    }
    archive_write_free(ext);

    ret = EX_OK;

    if (!should_stop && !is_error) {
        if (lstat("APPSCRIPT", &sbuf) == -1)
            err(EX_NOINPUT, "lstat(APPSCRIPT)");
        if (sbuf.st_uid != uid || !(sbuf.st_mode & S_IXUSR))
            errx(EX_NOPERM, "Operation not permitted");
        if (setenv("APPSCRIPT_PWD", extractdir, 1) == -1)
            err(EX_SOFTWARE, "setenv");
        if (setenv("APPSCRIPT_SCRIPT", iam, 1) == -1)
            err(EX_SOFTWARE, "setenv");
        posix_spawnattr_t pattr;
        if (posix_spawnattr_init(&pattr) != 0)
            err(EX_SOFTWARE, "posix_spawnattr_init");
        posix_spawnattr_setflags(&pattr, POSIX_SPAWN_SETPGROUP);
        posix_spawnattr_setpgroup(&pattr, 0);
        ret = posix_spawn(&pid, "./APPSCRIPT", NULL, &pattr, argv, environ);
        posix_spawnattr_destroy(&pattr);
        if (ret == 0) {
            child_pid = pid;
            while (waitpid(pid, &status, 0) == -1) {
                if (errno != EINTR) {
                    child_pid = 0;
                    return EX_SOFTWARE;
                }
            }
            child_pid = 0;
            if (WIFEXITED(status))
                ret = WEXITSTATUS(status);
            else
                ret = EX_SOFTWARE;
        } else {
            warn("posix_spawn");
            ret = EX_OSERR;
        }
    }

    if (!should_stop && !is_error)
        return ret;
    else
        return EX_SOFTWARE;
}

static void
cleanup(void)
{
    if (extractdir != NULL) {
        rm_tree((char *[]){ extractdir, NULL });
        extractdir = NULL;
    }
}

static void
on_signal(int sig)
{
    should_stop = 1;

    if (child_pid > 0)
        kill(-child_pid, sig);
}

static void ignore_signals(void)
{
    int sig;
    int *aux = ignored_signals;

    while ((sig = *aux++) != 0)
        signal(sig, SIG_IGN);
}

static void handle_signals(void)
{
    int sig;
    int *aux = handled_signals;

    while ((sig = *aux++) != 0)
        signal(sig, on_signal);
}

static char *whoami(void)
{
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PATHNAME, -1 };
    static char myself[PATH_MAX];
    size_t len = sizeof(myself);

    if (sysctl(mib, 4, myself, &len, NULL, 0) == -1)
        err(EX_SOFTWARE, "sysctl");

    return myself;
}

/*
 * Extracted from ${SRCTREE}/bin/rm/rm.c and adapted to get the same
 * behaviour of 'rm -rf'.
 */
static void
rm_tree(char **path_argv)
{
    FTS *fts;
    FTSENT *p;
    bool needstat;
    int flags;
    int rval;
    uid_t uid;

    uid = geteuid();

    needstat = uid == 0;

    flags = FTS_PHYSICAL;
    if (!needstat)
        flags |= FTS_NOSTAT;
    flags |= FTS_WHITEOUT;
    if (!(fts = fts_open(path_argv, flags, NULL))) {
        if (errno == ENOENT)
            return;
        warn("fts_open");
        return;
    }
    while (errno = 0, (p = fts_read(fts)) != NULL) {
        switch (p->fts_info) {
        case FTS_DNR:
            if (p->fts_errno != ENOENT) {
                warnx("%s: %s",
                    p->fts_path, strerror(p->fts_errno));
            }
            continue;
        case FTS_ERR:
            warnx("%s: %s", p->fts_path, strerror(p->fts_errno));
            return;
        case FTS_NS:
            /*
             * Assume that since fts_read() couldn't stat the
             * file, it can't be unlinked.
             */
            if (!needstat)
                break;
            if (p->fts_errno != ENOENT) {
                warnx("%s: %s",
                    p->fts_path, strerror(p->fts_errno));
            }
            continue;
        case FTS_D:
            if (uid == 0 &&
                 (p->fts_statp->st_flags & (UF_APPEND|UF_IMMUTABLE)) &&
                 !(p->fts_statp->st_flags & (SF_APPEND|SF_IMMUTABLE)) &&
                 lchflags(p->fts_accpath,
                     p->fts_statp->st_flags &= ~(UF_APPEND|UF_IMMUTABLE)) < 0)
                goto rm_err;
            continue;
        case FTS_DP:
            break;
        }

        rval = 0;
        if (uid == 0 &&
            (p->fts_statp->st_flags & (UF_APPEND|UF_IMMUTABLE)) &&
            !(p->fts_statp->st_flags & (SF_APPEND|SF_IMMUTABLE)))
            rval = lchflags(p->fts_accpath,
                       p->fts_statp->st_flags &= ~(UF_APPEND|UF_IMMUTABLE));
        if (rval == 0) {
            /*
             * If we can't read or search the directory, may still be
             * able to remove it.  Don't print out the un{read,search}able
             * message unless the remove fails.
             */
            switch (p->fts_info) {
            case FTS_DP:
            case FTS_DNR:
                rval = rmdir(p->fts_accpath);
                if (rval == 0 || errno == ENOENT)
                    continue;
                break;

            case FTS_W:
                rval = undelete(p->fts_accpath);
                if (rval == 0 || errno == ENOENT)
                    continue;
                break;

            case FTS_NS:
                /*
                 * Assume that since fts_read() couldn't stat
                 * the file, it can't be unlinked.
                 */
                continue;

            case FTS_F:
            case FTS_NSOK:
            default:
                rval = unlink(p->fts_accpath);
                if (rval == 0 || errno == ENOENT)
                    continue;
            }
        }
rm_err:
        warn("%s", p->fts_path);
    }
    fts_close(fts);
}
