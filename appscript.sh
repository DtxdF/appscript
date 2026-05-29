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

# Signals
IGNORED_SIGNALS="SIGALRM SIGVTALRM SIGPROF SIGUSR1 SIGUSR2"
HANDLER_SIGNALS="SIGHUP SIGINT SIGQUIT SIGTERM SIGXCPU SIGXFSZ"

BUILDDIR=
PREFIX="%%PREFIX%%"
SHAREDIR="${PREFIX}/share/appscript"

set -o pipefail

main()
{
    local _o
    local opt_dereference=false arg_dereference=
    local opt_static=false
    local compress_algo="zstd"
    local filename="a.AppScript"

    while getopts ":Lsvc:o:" _o; do
        case "${_o}" in
            L)
                opt_dereference=true
                ;;
            s)
                opt_static=true
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

    local format= machine_arch=

    machine_arch=`uname -p` || exit $?

    case "${machine_arch}" in
        amd64) format="elf64-x86-64" ;;
        *) log_err "Unsupported arch: ${machine_arch}" ;;
    esac

    trap '' ${IGNORED_SIGNALS}
    trap "ERRLEVEL=\$?; cleanup; exit \${ERRLEVEL}" EXIT
    trap "cleanup; exit 70" ${HANDLER_SIGNALS}

    BUILDDIR=`mktemp -d -t appscript` || exit $?

    if ${opt_dereference}; then
        arg_dereference="-L"
    fi

    tar ${arg_dereference} -c --${compress_algo} -C "${directory}" -f "${BUILDDIR}/payload" . || exit $?

    (
        cd -- "${BUILDDIR}" &&
            objcopy \
                --input-target binary \
                --output-target "${format}" \
                --rename-section .data=.rodata,alloc,load,readonly,contents \
                    payload payload.o &&
            rm -f payload || exit $?
    ) || exit $?

    local static_args=

    if ${opt_static}; then
        static_args="-static -lbz2 -lz -lprivatezstd -llzma -lmd -lcrypto -lbsdxml -lpthread"
    fi

    clang -O3 -s -pipe "${BUILDDIR}/payload.o" "${SHAREDIR}/stub.c" -o "${filename}" -larchive ${static_args} || exit $?

    exit ${EX_OK}
}

log_err()
{
    echo "===> $*" >&2
}

cleanup()
{
    trap '' ${HANDLER_SIGNALS} EXIT
    if [ -n "${BUILDDIR}" ]; then
        rm -rf -- "${BUILDDIR}" > /dev/null 2>&1
    fi
    trap - ${IGNORED_SIGNALS} ${HANDLER_SIGNALS} EXIT
}

version()
{
    echo "${VERSION}"
}

usage()
{
    cat << EOF
usage: appscript -v
       appscript [-Ls] [-c [gzip|xz|zstd]] [-o <filename>] <directory>
EOF
}

main "$@"
