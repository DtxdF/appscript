MKDIR?=mkdir -p
INSTALL?=install
SED?=sed -i ''
RM?=rm -f
PREFIX?=/usr/local
MANDIR?=${PREFIX}/share/man

APPSCRIPT_VERSION?=0.3.5

all: install

install:
	${MKDIR} -m 755 -p "${DESTDIR}${PREFIX}/share"
	${MKDIR} -m 755 -p "${DESTDIR}${PREFIX}/share/appscript"
	${MKDIR} -m 755 -p "${DESTDIR}${MANDIR}"
	${MKDIR} -m 755 -p "${DESTDIR}${MANDIR}/man1"
	${INSTALL} -m 444 appscript.1 "${DESTDIR}${MANDIR}/man1/appscript.1"
	${MKDIR} -m 755 -p "${DESTDIR}${PREFIX}/bin"
	${INSTALL} -m 444 stub.c "${DESTDIR}${PREFIX}/share/appscript/stub.c"
	${INSTALL} -m 555 appscript.sh "${DESTDIR}${PREFIX}/bin/appscript"
	${SED} -e 's|%%VERSION%%|${APPSCRIPT_VERSION}|' "${DESTDIR}${PREFIX}/bin/appscript"
	${SED} -e 's|%%PREFIX%%|${PREFIX}|' "${DESTDIR}${PREFIX}/bin/appscript"

uninstall:
	${RM} "${DESTDIR}${MANDIR}/man1/appscript.1"
	${RM} "${DESTDIR}${PREFIX}/bin/appscript"
	${RM} -r "${DESTDIR}${PREFIX}/share/appscript"

docs:
	@mandoc -T ascii appscript.1 | col -b | tail +3 | sed -e '$$d' | sed -e '$$d' > README.txt
