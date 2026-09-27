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

set -o pipefail

# AppScript version.
VERSION="%%VERSION%%"

# see sysexits(3)
EX_OK=0
EX_USAGE=64
EX_DATAERR=65
EX_NOINPUT=66

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
    local opt_display_checksum=false
    local opt_dereference=false arg_dereference=
    local mcmodel="small"
    local opt_static=false
    local checksum_algo="sha256"
    local machine_arch=
    local compress_algo="zstd"
    local vendorid=
    local sign_key=
    local target=
    local filename="a.AppScript"
    local sysroot=

    while getopts ":CLMsvA:a:c:I:i:o:S:" _o; do
        case "${_o}" in
            C)
                opt_display_checksum=true
                ;;
            L)
                opt_dereference=true
                ;;
            M)
                if [ "${mcmodel}" = "small" ]; then
                    mcmodel="medium"
                elif [ "${mcmodel}" = "medium" ]; then
                    mcmodel="large"
                fi
                ;;
            s)
                opt_static=true
                ;;
            v)
                version
                exit ${EX_OK}
                ;;
            A)
                checksum_algo="${OPTARG}"
                ;;
            a)
                machine_arch="${OPTARG}"
                ;;
            c)
                compress_algo="${OPTARG}"
                ;;
            I)
                vendorid="${OPTARG}"
                ;;
            i)
                sign_key="${OPTARG}"
                ;;
            o)
                filename="${OPTARG}"
                ;;
            S)
                sysroot="${OPTARG}"
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
        *) log_err "Unsupported compression algorithm: ${compress_algo}"; exit ${EX_DATAERR} ;;
    esac

    case "${checksum_algo}" in
        sha256|blake3) ;;
        *) log_err "Unsupported checksum algorithm: ${checksum_algo}"; exit ${EX_DATAERR} ;;
    esac

    local format=

    machine_arch="${machine_arch:-`uname -p`}" || exit $?

    case "${machine_arch}" in
        amd64) format="elf64-x86-64" ;;
        aarch64) format="elf64-littleaarch64" ;;
        armv7) format="elf32-littlearm" ;;
        i386) format="elf32-i386" ;;
        riscv64) format="elf64-littleriscv" ;;
        powerpc) format="elf32-powerpc" ;;
        powerpc64) format="elf64-powerpc" ;;
        powerpc64le) format="elf64-powerpcle" ;;
        *) log_err "Unsupported arch: ${machine_arch}" ;;
    esac

    if [ -z "${sysroot}" ]; then
        sysroot="${PREFIX}/freebsd-sysroot/${machine_arch}"

        # If 'uname -p' is the same as '${machine_arch}', we should use
        # '/' which is especially more important when '${opt_static}'
        # is 'true'.
        if [ ! -d "${sysroot}" ] || [ "${machine_arch}" = "`uname -p`" ]; then
            sysroot="/"
        fi
    fi

    atexit_init

    BUILDDIR=`mktemp -d -t appscript` || exit $?

    if ${opt_dereference}; then
        arg_dereference="-L"
    fi

    tar ${arg_dereference} -c --${compress_algo} -C "${directory}" -f "${BUILDDIR}/payload" . || exit $?

    local payload_checksum
    if [ "${checksum_algo}" = "sha256" ]; then
        payload_checksum=`sha256 -q -- "${BUILDDIR}/payload"` || exit $?
    elif [ "${checksum_algo}" = "blake3" ]; then
        payload_checksum=`b3sum --no-names -- "${BUILDDIR}/payload"` || exit $?
    fi

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

    local out="${filename}"

    if [ -n "${sign_key}" ] || [ -n "${vendorid}" ]; then
        out="${BUILDDIR}/appscript"
    fi

    clang -O3 -s -pipe -mcmodel="${mcmodel}" --sysroot="${sysroot}" \
        -fno-asynchronous-unwind-tables \
        -DPAYLOAD_CHECKSUM="\"${payload_checksum}\"" \
        -target "${machine_arch}-unknown-freebsd" "${BUILDDIR}/payload.o" \
        "${SHAREDIR}/stub.c" -o "${out}" -larchive ${static_args} || exit $?

    if [ -n "${vendorid}" ]; then
        printf "%s" "${vendorid}" > "${BUILDDIR}/vendorid" || exit $?

        objcopy --add-section .vendorid="${BUILDDIR}/vendorid" \
            --set-section-flags .vendorid=noload,readonly \
            "${out}" "${BUILDDIR}/appscript.vendor" || exit $?

        mv -- "${BUILDDIR}/appscript.vendor" "${out}" || exit $?
    fi

    if [ -n "${sign_key}" ]; then
        local checksum
        if [ "${checksum_algo}" = "sha256" ]; then
            checksum=`sha256 -q -- "${out}"` || exit $?
        elif [ "${checksum_algo}" = "blake3" ]; then
            checksum=`b3sum --no-names -- "${out}"` || exit $?
        fi

        if ${opt_display_checksum}; then
            printf "%s\n" "${checksum}"
        fi

        printf "%s" "${checksum}" > "${BUILDDIR}/checksum" || exit $?

        signify -S -c "verify with appscript-verify" -s "${sign_key}" -m "${BUILDDIR}/checksum" \
            -x "${BUILDDIR}/appscript.sig" || exit $?

        echo >> "${out}" || exit $?
        echo -n "${checksum_algo}|" >> "${out}" || exit $?
        cat -- "${BUILDDIR}/appscript.sig" >> "${out}" || exit $?

        mv -- "${out}" "${filename}" || exit $?
    fi

    exit ${EX_OK}
}

atexit_init()
{
    trap '' ${IGNORED_SIGNALS}
    trap "ERRLEVEL=\$?; cleanup; exit \${ERRLEVEL}" EXIT
    trap "cleanup; exit 70" ${HANDLER_SIGNALS}
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
       appscript [-CLMs] [-A <algo>] [-a <arch>] [-c <algo>] [-I <vendorid>]
               [-i <sign-key>] [-o <filename>] [-S <sysroot>] <directory>
EOF
}

main_verify()
{
    local _o
    local opt_print_vendorid=false
    local checksum=
    local public_key=

    while getopts ":PC:p:" _o; do
        case "${_o}" in
            P)
                opt_print_vendorid=true
                ;;
            C)
                checksum="${OPTARG}"
                ;;
            p)
                public_key="${OPTARG}"
                ;;
            *)
                usage_verify
                exit ${EX_USAGE}
                ;;
        esac
    done
    shift $((OPTIND-1))

    if [ -n "${public_key}" ] && ${opt_print_vendorid}; then
        usage_verify
        exit ${EX_USAGE}
    fi

    local filename="$1"
    
    if [ -z "${filename}" ]; then
        usage_verify
        exit ${EX_USAGE}
    fi

    if [ ! -f "${filename}" ]; then
        log_err "${filename}: file not found or no read permission."
        exit ${EX_NOINPUT}
    fi

    if ${opt_print_vendorid}; then
        atexit_init

        local section_info
        section_info=`readelf -W -S "${filename}" 2>/dev/null | awk '$2 == ".vendorid" {print toupper($5), toupper($6)}'`

        if [ -z "${section_info}" ]; then
            log_err "No vendor ID section found."
            exit 1
        fi

        local hex_offset hex_size
        hex_offset=`echo "${section_info}" | awk '{print $1}'`
        hex_size=`echo "${section_info}" | awk '{print $2}'`

        local offset size
        offset=`echo "ibase=16; ${hex_offset}" | bc`
        size=`echo "ibase=16; ${hex_size}" | bc`

        BUILDDIR=`mktemp -d -t appscript` || exit $?

        if ! dd if="${filename}" bs=1 skip="${offset}" count="${size}" 2>/dev/null > "${BUILDDIR}/vendorid"; then
            log_err "Failed to extract vendor ID section."
            exit 1
        fi

        local vendorid
        vendorid=`head -1 -- "${BUILDDIR}/vendorid"` || exit $?

        printf "%s\n" "${vendorid}"
    else
        if [ -z "${public_key}" ]; then
            usage_verify
            exit ${EX_USAGE}
        fi

        atexit_init

        BUILDDIR=`mktemp -d -t appscript` || exit $?

        local checksum_algo

        tail -c 256 -- "${filename}" |\
            grep -a -A1 -Ee '^(sha256|blake3)|untrusted comment:' > "${BUILDDIR}/appscript.tail"

        if [ $? -ne 0 ]; then
            tail -c 256 -- "${filename}" |\
                grep -a -A1 -Ee '^untrusted comment:' > "${BUILDDIR}/appscript.tail"

            if [ $? -ne 0 ]; then
                log_err "No signature was found."
                exit 1
            fi

            cp -- "${BUILDDIR}/appscript.tail" "${BUILDDIR}/appscript.sig" || exit $?

            # Backward compatibility.
            checksum_algo="sha256"
        else
            cut -s -d"|" -f1 -- "${BUILDDIR}/appscript.tail" > "${BUILDDIR}/appscript.checksum_algo" || exit $?
            sed -Ee 's/^(sha256|blake3)\|//' -- "${BUILDDIR}/appscript.tail" > "${BUILDDIR}/appscript.sig" || exit $?

            checksum_algo=`head -1 -- "${BUILDDIR}/appscript.checksum_algo"` || exit $?
        fi

        case "${checksum_algo}" in
            sha256|blake3) ;;
            *) checksum_algo="sha256" ;;
        esac

        if [ "${checksum_algo}" = "blake3" ] && ! which -s b3sum; then
            log_err "sysutils/b3sum is required to be installed to verify this AppScript."
            exit 1
        fi

        if [ -z "${checksum}" ]; then
            local sig_size
            sig_size=`stat -f %z -- "${BUILDDIR}/appscript.tail"` || exit $?

            local total_size
            total_size=`stat -f %z -- "${filename}"` || exit $?

            local orig_size
            orig_size=$(( total_size - sig_size - 1 ))

            if [ "${checksum_algo}" = "sha256" ]; then
                checksum=`head -c "${orig_size}" "${filename}" | sha256 -q` || exit $?
            elif [ "${checksum_algo}" = "blake3" ]; then
                checksum=`head -c "${orig_size}" "${filename}" | b3sum --no-names` || exit $?
            fi
        fi

        printf "%s" "${checksum}" > "${BUILDDIR}/checksum" || exit $?

        signify -V -p "${public_key}" -m "${BUILDDIR}/checksum" \
            -x "${BUILDDIR}/appscript.sig" || exit $?
    fi

    exit ${EX_OK}
}

usage_verify()
{
    cat << EOF
usage: appscript-verify -P <filename>
       appscript-verify [-c <checksum>] -p <public-key> <filename>
EOF
}

self=`basename -- "$0"` || exit $?

case "${self}" in
    appscript-verify) main_verify "$@" ;;
    *) main "$@" ;;
esac
