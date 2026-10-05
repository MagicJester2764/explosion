# Read by make before coreutils' own Makefile (through MAKEFILES), and
# before each of the GNU programs' build-gnu-tools.sh builds, which carry
# the same gnulib.
#
# One file in gnulib, getlocalename_l-unsafe.c, has to reach inside the C
# library for the name of a locale, and so asks which C library it has. It
# asks by asking which system it is on, has never heard of Quark, and stops:
# "#error Please port gnulib getlocalename_l-unsafe.c to your platform!".
#
# The C library here is musl, and the file knows musl's way — an ordinary
# nl_langinfo_l call — but keeps it under the heading of Linux, since that is
# the only place it has met musl. So that one object is compiled being told
# it is on Linux. Nothing else is: every other file that asks gets the truth
# and takes the path that asks nothing of a particular kernel.
#
# The object's name is written out: this is read before the Makefile that
# says what an object file is called.
lib/libcoreutils_a-getlocalename_l-unsafe.o: CFLAGS += -D__linux__
# And as the others call it: by its own name, in their gnulib directories
# and their test suites', or prefixed with a library's.
getlocalename_l-unsafe.o: CFLAGS += -D__linux__
%-getlocalename_l-unsafe.o: CFLAGS += -D__linux__
