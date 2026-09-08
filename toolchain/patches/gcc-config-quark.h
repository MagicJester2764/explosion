/* Quark, an x86-64 microkernel with user-space servers.
   Contributed as part of the x86_64-quark port.

This file is part of GCC.

GCC is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 3, or (at your option)
any later version.

GCC is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with GCC; see the file COPYING3.  If not see
<http://www.gnu.org/licenses/>.  */

/* A Quark program is loaded above 512 GiB, is not relocated, and runs with no
   red zone.  Those are properties of the system rather than of any one
   program, so they are the target's defaults rather than flags every Makefile
   has to know to repeat -- which is the point of having a target triple
   instead of a pile of switches.  Each stays overridable.  */
#undef  DRIVER_SELF_SPECS
#define DRIVER_SELF_SPECS						\
  "%{!mcmodel=*:-mcmodel=large}",					\
  "%{!mred-zone:%{!mno-red-zone:-mno-red-zone}}",			\
  "%{!fpic:%{!fPIC:%{!fpie:%{!fPIE:%{!fno-pic:-fno-pic}}}}}"

/* The entry point builds argv out of a page the spawner maps, so it is a real
   object rather than a stub.  */
#undef  STARTFILE_SPEC
#define STARTFILE_SPEC "crt0%O%s"

#undef  ENDFILE_SPEC
#define ENDFILE_SPEC ""

#undef  LIB_SPEC
#define LIB_SPEC "-lc"

/* The link script belongs to the target for the same reason the code model
   does: the base address and the entry section are the system's, not any one
   program's.  Named by absolute path through the sysroot, because `ld' does
   not look for a `-T' script along the library search path the way it does
   for a library.  Naming one explicitly still wins, so a program that needs a
   different layout can say so.

   Static and non-PIE: there is no dynamic loader.  No build ID, which has
   nowhere to be read from here.  */
#undef  LINK_SPEC
#define LINK_SPEC \
  "%{!shared:-static} -no-pie -z noexecstack --build-id=none \\
   %{!T*:-T %R/usr/lib/quark.ld}"

#undef  TARGET_OS_CPP_BUILTINS
#define TARGET_OS_CPP_BUILTINS()		\
  do						\
    {						\
      builtin_define ("__quark__");		\
      builtin_define ("__ELF__");		\
      builtin_assert ("system=quark");		\
    }						\
  while (false)
