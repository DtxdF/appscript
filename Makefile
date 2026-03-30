MKDIR?=mkdir -p
INSTALL?=install
SED?=sed -i ''
RM?=rm -f
PREFIX?=/usr/local
MANDIR?=${PREFIX}/share/man

APPSCRIPT_VERSION?=0.0.2

all: install

install:
	${MKDIR} -m 755 -p "${DESTDIR}${MANDIR}"
	${MKDIR} -m 755 -p "${DESTDIR}${MANDIR}/man1"
	${INSTALL} -m 444 appscript.1 "${DESTDIR}${MANDIR}/man1/appscript.1"
	${MKDIR} -m 755 -p "${DESTDIR}${PREFIX}/bin"
	${INSTALL} -m 555 appscript.sh "${DESTDIR}${PREFIX}/bin/appscript"
	${SED} -e 's|%%VERSION%%|${APPSCRIPT_VERSION}|' "${DESTDIR}${PREFIX}/bin/appscript"

uninstall:
	${RM} "${DESTDIR}${MANDIR}/man1/appscript.1"
	${RM} "${DESTDIR}${PREFIX}/bin/appscript"

docs:
	mandoc -T ascii appscript.1 | col -b | tail +3 | sed -e '$$d' | sed -e '$$d' > README.txt
