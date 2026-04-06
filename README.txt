NAME
     appscript - Simple, lightweight and effective tool for creating SFX files

SYNOPSIS
     appscript -v
     appscript [-L] [-c [gzip|xz|zstd]] [-o filename] directory

DESCRIPTION
     appscript is a very lightweight and easy-to-use tool for creating self-
     extracting executables.

     From the developer's perspective, tar(1) is used to compress a directory,
     called the "payload," objcopy(1) to convert the payload into a valid
     elf(3) object file, and then clang(1) to compile the payload with the C-
     written stub. And from the user's perspective, it just need to run the
     executable file, and the magic happens behind the scenes: the AppScript
     (the SFX file) reads the addresses where the payload is located and uses
     libarchive(3) to extract the files to a temporary directory, finally
     executing an executable file named APPSCRIPT. The user can pass any
     environment variables and arguments to the AppScript, and the APPSCRIPT
     executable can handle them just like any other program or script.

     But the AppScript does much more than described above. First, it sets
     handlers for SIGHUP, SIGINT, SIGQUIT, SIGTERM, SIGXCPU, and SIGXFSZ to
     stop the AppScript when it's running.  SIGALRM, SIGVTALRM, SIGPROF,
     SIGUSR1, and SIGUSR2 are ignored. Next, it checks if the
     /var/tmp/appscript directory exists and, if so, uses it to create
     temporary directories; otherwise, /tmp is used as fallback. The reason
     /var/tmp/appscript is preferred is that a system administrator can
     configure this location to mount a tmpfs(4) filesystem to improve the
     performance of very large AppScripts. This is more secure than setting
     "vfs.usermount=1" and letting the user (or, in this case, the user's
     process) mount a tmpfs(4) filesystem. Regardless of the directory used,
     it must have file mode 1777; otherwise, an EX_NOPERM error will be
     returned. After initial checks, the tarball is extracted to a temporary
     location determined by the directories mentioned above.  The AppScript
     will refuse to extract absolute paths and entries containing periods, and
     will apply basic protection against symbolic links (see
     ARCHIVE_EXTRACT_SECURE_SYMLINKS in archive_write_disk(3) for details).
     Finally, if no signal is received and no errors are detected during the
     files extraction, the AppScript will attempt to execute the APPSCRIPT
     file. For this to succeed, the file must have the execute bit set and the
     owner must be the same as the effective uid, which should be the case
     since the uid and gid are changed to the caller when the files are
     extracted. As a final task, the temporary directory is recursively
     removed in a similar way to the -r -and -f flags in rm(1).

     -L   All symbolic links will be followed.
	  Normally, symbolic links are archived as such. With this option, the
	  target of the link will be archived instead.

     -v   Display version information about appscript.

     -o filename
	  Name of the resulting executable. By default, a.AppScript.

     directory
	  Directory to be compressed.

	  appscript assumes that the APPSCRIPT script is already present and
	  has the execute bit set.

ENVIRONMENT
     APPSCRIPT_PWD
	  Since APPSCRIPT runs from the current user's working directory, it
	  does not know the location of the temporary directory. This
	  environment variable specifies that location.

     APPSCRIPT_SCRIPT
	  Absolute path to the AppScript that is currently running.

SEE ALSO
     tar(1) libarchive(3) signal(3) sysexits(3)

AUTHORS
     Jesus Daniel Colmenares Oviedo <DtxdF@disroot.org>
