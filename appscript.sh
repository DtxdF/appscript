#!/bin/sh
#
# Copyright (c) 2026, Jesús Daniel Colmenares Oviedo <dtxdf@disroot.org>
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# * Redistributions of source code must retain the above copyright notice, this
#   list of conditions and the following disclaimer.
#
# * Redistributions in binary form must reproduce the above copyright notice,
#   this list of conditions and the following disclaimer in the documentation
#   and/or other materials provided with the distribution.
#
# * Neither the name of the copyright holder nor the names of its
#   contributors may be used to endorse or promote products derived from
#   this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
# SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
# CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
# OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

# AppScript version.
VERSION="%%VERSION%%"

# see sysexits(3)
EX_OK=0
EX_USAGE=64

set -o pipefail

main()
{
    local _o
    local opt_use_tmpfs=false
    local compress_algo="xz"
    local filename="/dev/stdout"

    while getopts ":tvc:o:" _o; do
        case "${_o}" in
            t)
                opt_use_tmpfs="${OPTARG}"
                ;;
            v)
                version
                exit ${EX_OK}
                ;;
            c)
                compress_algo="${OPTARG}"
                ;;
            o)
                filename="${OPTARG}"
                ;;
            *)
                usage
                exit ${EX_USAGE}
                ;;
        esac
    done
    shift $((OPTIND-1))

    local directory="$1"

    if [ -z "${directory}" ]; then
        usage
        exit ${EX_USAGE}
    fi

    case "${compress_algo}" in
        gzip|xz|zstd) ;;
        *) usage; exit ${EX_USAGE} ;;
    esac

    local compressed_file
    compressed_file=`tar -C "${directory}" --${compress_algo} -cf - . | base64 -w 0` || exit $?

    cat << EOF > "${filename}" || exit $?
#!/bin/sh

set -T
set -o pipefail

APPSCRIPT_VERSION="${VERSION}"
USE_TMPFS="${opt_use_tmpfs}"
IGNORED_SIGNALS="SIGALRM SIGVTALRM SIGPROF SIGUSR1 SIGUSR2"
HANDLER_SIGNALS="SIGHUP SIGINT SIGQUIT SIGTERM SIGXCPU SIGXFSZ"
TEMPDIR=
COMPRESSED_FILE="${compressed_file}"

can_tmpfs()
{
    \${USE_TMPFS} && [ "\`sysctl -n vfs.usermount\`" -eq 1 ]
}

cleanup()
{
    trap '' \${HANDLER_SIGNALS} EXIT
    if [ -n "\${TEMPDIR}" ]; then
        if can_tmpfs; then
            umount -- "\${TEMPDIR}" > /dev/null 2>&1
        fi
        rm -rf -- "\${TEMPDIR}" > /dev/null 2>&1
    fi
    trap - \${IGNORED_SIGNALS} \${HANDLER_SIGNALS} EXIT
}

trap '' \${IGNORED_SIGNALS}
trap "ERRLEVEL=\\\$?; cleanup; exit \\\${ERRLEVEL}" EXIT
trap "cleanup; exit 70" \${HANDLER_SIGNALS}

TEMPDIR=\`mktemp -d -t appscript\` || exit \$?

if can_tmpfs; then
    mount -t tmpfs tmpfs "\${TEMPDIR}"
fi

printf "%s" "\${COMPRESSED_FILE}" | base64 -d | tar -C "\${TEMPDIR}" -xf - || exit \$?

APPSCRIPT_PWD="\${TEMPDIR}" \\
    "\${TEMPDIR}/APPSCRIPT" "$@" || exit \$?

exit ${EX_OK}
EOF

    if [ -f "${filename}" ]; then
        chmod +x "${filename}" || exit $?
    fi

    exit ${EX_OK}
}

version()
{
    echo "${VERSION}"
}

usage()
{
    cat << EOF
usage: appscript -v
       appscript [-t] [-c [gzip|xz|zstd]] [-o <filename>] <directory>
EOF
}

main "$@"
