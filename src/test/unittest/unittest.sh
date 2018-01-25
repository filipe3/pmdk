#
# Copyright 2014-2018, Intel Corporation
# Copyright (c) 2016, Microsoft Corporation. All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
#
#     * Redistributions of source code must retain the above copyright
#       notice, this list of conditions and the following disclaimer.
#
#     * Redistributions in binary form must reproduce the above copyright
#       notice, this list of conditions and the following disclaimer in
#       the documentation and/or other materials provided with the
#       distribution.
#
#     * Neither the name of the copyright holder nor the names of its
#       contributors may be used to endorse or promote products derived
#       from this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
# "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
# LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
# A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
# OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
# SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
# LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
# DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
# THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#
set -e

# make sure we have a well defined locale for string operations here
export LC_ALL="C"
#export LC_ALL="en_US.UTF-8"

. ../testconfig.sh

function verbose_msg() {
	if [ "$UNITTEST_LOG_LEVEL" -ge 2 ]; then
		echo "$*"
	fi
}

function msg() {
	if [ "$UNITTEST_LOG_LEVEL" -ge 1 ]; then
		echo "$*"
	fi
}

function fatal() {
	echo "$*" >&2
	exit 1
}

# defaults
[ "$UNITTEST_LOG_LEVEL" ] || export UNITTEST_LOG_LEVEL=2
[ "$GREP" ] || export GREP="grep -a"
[ "$TEST" ] || export TEST=check
[ "$FS" ] || export FS=any
[ "$BUILD" ] || export BUILD=debug
[ "$CHECK_TYPE" ] || export CHECK_TYPE=auto
[ "$CHECK_POOL" ] || export CHECK_POOL=0
[ "$VERBOSE" ] || export VERBOSE=0
[ -n "${SUFFIX+x}" ] || export SUFFIX="😘⠝⠧⠍⠇ɗNVMLӜ⥺🙋"

TOOLS=../tools
# Paths to some useful tools
[ "$PMEMPOOL" ] || PMEMPOOL=../../tools/pmempool/pmempool
[ "$PMEMSPOIL" ] || PMEMSPOIL=$TOOLS/pmemspoil/pmemspoil.static-nondebug
[ "$BTTCREATE" ] || BTTCREATE=$TOOLS/bttcreate/bttcreate.static-nondebug
[ "$PMEMWRITE" ] || PMEMWRITE=$TOOLS/pmemwrite/pmemwrite
[ "$PMEMALLOC" ] || PMEMALLOC=$TOOLS/pmemalloc/pmemalloc
[ "$PMEMOBJCLI" ] || PMEMOBJCLI=$TOOLS/pmemobjcli/pmemobjcli
[ "$PMEMDETECT" ] || PMEMDETECT=$TOOLS/pmemdetect/pmemdetect.static-nondebug
[ "$FIP" ] || FIP=$TOOLS/fip/fip
[ "$DDMAP" ] || DDMAP=$TOOLS/ddmap/ddmap
[ "$CMPMAP" ] || CMPMAP=$TOOLS/cmpmap/cmpmap

# force globs to fail if they don't match
shopt -s failglob

# number of remote nodes required in the current unit test
NODES_MAX=-1

# SSH and SCP options
SSH_OPTS="-o BatchMode=yes"
SCP_OPTS="-o BatchMode=yes -r -p"

# list of common files to be copied to all remote nodes
DIR_SRC="../.."
FILES_COMMON_DIR="\
$DIR_SRC/test/*.supp \
$DIR_SRC/tools/rpmemd/rpmemd \
$DIR_SRC/tools/pmempool/pmempool \
$DIR_SRC/test/tools/ctrld/ctrld \
$DIR_SRC/test/tools/fip/fip"

# Portability
VALGRIND_SUPP="--suppressions=../ld.supp --suppressions=../memcheck-libunwind.supp"
if [ "$(uname -s)" = "FreeBSD" ]; then
	DATE="gdate"
	DD="gdd"
	VM_OVERCOMMIT="[ $(sysctl vm.overcommit | awk '{print $2}') == 0 ]"
	RM_ONEFS="-x"
	STAT_MODE="-f%Lp"
	STAT_PERM="-f%Sp"
	STAT_SIZE="-f%z"
	STRACE="truss"
	VALGRIND_SUPP="$VALGRIND_SUPP --suppressions=../freebsd.supp"
else
	DATE="date"
	DD="dd"
	VM_OVERCOMMIT="[ $(cat /proc/sys/vm/overcommit_memory) != 2 ]"
	RM_ONEFS="--one-file-system"
	STAT_MODE="-c%a"
	STAT_PERM="-c%A"
	STAT_SIZE="-c%s"
	STRACE="strace"
fi

# array of lists of PID files to be cleaned in case of an error
NODE_PID_FILES[0]=""

#
# For non-static build testing, the variable TEST_LD_LIBRARY_PATH is
# constructed so the test pulls in the appropriate library from this
# source tree.  To override this behavior (i.e. to force the test to
# use the libraries installed elsewhere on the system), set
# TEST_LD_LIBRARY_PATH and this script will not override it.
#
# For example, in a test directory, run:
#	TEST_LD_LIBRARY_PATH=/usr/lib ./TEST0
#
[ "$TEST_LD_LIBRARY_PATH" ] || {
	case "$BUILD"
	in
	debug)
		TEST_LD_LIBRARY_PATH=../../debug
		REMOTE_LD_LIBRARY_PATH=../debug
		;;
	nondebug)
		TEST_LD_LIBRARY_PATH=../../nondebug
		REMOTE_LD_LIBRARY_PATH=../nondebug
		;;
	esac
}

#
# When running static binary tests, append the build type to the binary
#
case "$BUILD"
in
	static-*)
		EXESUFFIX=.$BUILD
		;;
esac

#
# The variable DIR is constructed so the test uses that directory when
# constructing test files.  DIR is chosen based on the fs-type for
# this test, and if the appropriate fs-type doesn't have a directory
# defined in testconfig.sh, the test is skipped.
#
# This behavior can be overridden by setting DIR.  For example:
#	DIR=/force/test/dir ./TEST0
#
curtestdir=`basename $PWD`

# just in case
if [ ! "$curtestdir" ]; then
	fatal "curtestdir does not have a value"
fi

curtestdir=test_$curtestdir

if [ ! "$UNITTEST_NUM" ]; then
	fatal "UNITTEST_NUM does not have a value"
fi

if [ ! "$UNITTEST_NAME" ]; then
	fatal "UNITTEST_NAME does not have a value"
fi

REAL_FS=$FS
if [ "$DIR" ]; then
	DIR=$DIR/$curtestdir$UNITTEST_NUM$SUFFIX
else
	case "$FS"
	in
	pmem)
		DIR=$PMEM_FS_DIR/$DIRSUFFIX/$curtestdir$UNITTEST_NUM$SUFFIX
		if [ "$PMEM_FS_DIR_FORCE_PMEM" = "1" ]; then
			export PMEM_IS_PMEM_FORCE=1
		fi
		;;
	non-pmem)
		DIR=$NON_PMEM_FS_DIR/$DIRSUFFIX/$curtestdir$UNITTEST_NUM$SUFFIX
		;;
	any)
		if [ "$PMEM_FS_DIR" != "" ]; then
			DIR=$PMEM_FS_DIR/$DIRSUFFIX/$curtestdir$UNITTEST_NUM$SUFFIX
			REAL_FS=pmem
			if [ "$PMEM_FS_DIR_FORCE_PMEM" = "1" ]; then
				export PMEM_IS_PMEM_FORCE=1
			fi
		elif [ "$NON_PMEM_FS_DIR" != "" ]; then
			DIR=$NON_PMEM_FS_DIR/$DIRSUFFIX/$curtestdir$UNITTEST_NUM$SUFFIX
			REAL_FS=non-pmem
		else
			fatal "$UNITTEST_NAME: fs-type=any and both env vars are empty"
		fi
		;;
	none)
		DIR=/dev/null/not_existing_dir/$DIRSUFFIX/$curtestdir$UNITTEST_NUM$SUFFIX
		;;
	*)
		verbose_msg "$UNITTEST_NAME: SKIP fs-type $FS (not configured)"
		exit 0
		;;
	esac
fi

if [ -d "$PMEM_FS_DIR" ]; then
	if [ "$PMEM_FS_DIR_FORCE_PMEM" = "1" ]; then
		PMEM_IS_PMEM=0
	else
		$PMEMDETECT "$PMEM_FS_DIR" && true
		PMEM_IS_PMEM=$?
	fi
fi

if [ -d "$NON_PMEM_FS_DIR" ]; then
	$PMEMDETECT "$NON_PMEM_FS_DIR" && true
	NON_PMEM_IS_PMEM=$?
fi

# writes test working directory to temporary file
# that allows read location of data after test failure
if [ -f "$TEMP_LOC" ]; then
	echo "$DIR" > $TEMP_LOC
fi


#
# The default is to turn on library logging to level 3 and save it to local files.
# Tests that don't want it on, should override these environment variables.
#
export VMEM_LOG_LEVEL=3
export VMEM_LOG_FILE=vmem$UNITTEST_NUM.log
export PMEM_LOG_LEVEL=3
export PMEM_LOG_FILE=pmem$UNITTEST_NUM.log
export PMEMBLK_LOG_LEVEL=3
export PMEMBLK_LOG_FILE=pmemblk$UNITTEST_NUM.log
export PMEMLOG_LOG_LEVEL=3
export PMEMLOG_LOG_FILE=pmemlog$UNITTEST_NUM.log
export PMEMOBJ_LOG_LEVEL=3
export PMEMOBJ_LOG_FILE=pmemobj$UNITTEST_NUM.log
export PMEMCTO_LOG_LEVEL=3
export PMEMCTO_LOG_FILE=pmemcto$UNITTEST_NUM.log
export PMEMPOOL_LOG_LEVEL=3
export PMEMPOOL_LOG_FILE=pmempool$UNITTEST_NUM.log

export VMMALLOC_POOL_DIR="$DIR"
export VMMALLOC_POOL_SIZE=$((16 * 1024 * 1024))
export VMMALLOC_LOG_LEVEL=3
export VMMALLOC_LOG_FILE=vmmalloc$UNITTEST_NUM.log

export OUT_LOG_FILE=out$UNITTEST_NUM.log
export ERR_LOG_FILE=err$UNITTEST_NUM.log
export TRACE_LOG_FILE=trace$UNITTEST_NUM.log
export PREP_LOG_FILE=prep$UNITTEST_NUM.log

export VALGRIND_LOG_FILE=${CHECK_TYPE}${UNITTEST_NUM}.log
export VALIDATE_VALGRIND_LOG=1

export RPMEM_LOG_LEVEL=3
export RPMEM_LOG_FILE=rpmem$UNITTEST_NUM.log
export RPMEMD_LOG_LEVEL=info
export RPMEMD_LOG_FILE=rpmemd$UNITTEST_NUM.log

export REMOTE_VARS="
RPMEMD_LOG_FILE
RPMEMD_LOG_LEVEL
RPMEM_LOG_FILE
RPMEM_LOG_LEVEL
PMEM_LOG_FILE
PMEM_LOG_LEVEL
PMEMOBJ_LOG_FILE
PMEMOBJ_LOG_LEVEL
PMEMPOOL_LOG_FILE
PMEMPOOL_LOG_LEVEL"

[ "$UT_DUMP_LINES" ] || UT_DUMP_LINES=30

export CHECK_POOL_LOG_FILE=check_pool_${BUILD}_${UNITTEST_NUM}.log

# In case a lock is required for Device DAXes
DEVDAX_LOCK=../devdax.lock

#
# store_exit_on_error -- store on a stack a sign that reflects the current state
#                        of the 'errexit' shell option
#
function store_exit_on_error() {
	if [ "${-#*e}" != "$-" ]; then
		estack+=-
	else
		estack+=+
	fi
}

#
# restore_exit_on_error -- restore the state of the 'errexit' shell option
#
function restore_exit_on_error() {
	if [ -z $estack ]; then
		fatal "error: store_exit_on_error function has to be called first"
	fi

	eval "set ${estack:${#estack}-1:1}e"
	estack=${estack%?}
}

#
# disable_exit_on_error -- store the state of the 'errexit' shell option and
#                          disable it
#
function disable_exit_on_error() {
	store_exit_on_error
	set +e
}


#
# get_files -- print list of files in the current directory matching the given regex to stdout
#
# This function has been implemented to workaround a race condition in
# `find`, which fails if any file disappears in the middle of the operation.
#
# example, to list all *.log files in the current directory
#	get_files ".*\.log"
function get_files() {
	disable_exit_on_error
	ls -1 | grep -E "^$*$"
	restore_exit_on_error
}

#
# get_executables -- print list of executable files in the current directory to stdout
#
# This function has been implemented to workaround a race condition in
# `find`, which fails if any file disappears in the middle of the operation.
#
function get_executables() {
	disable_exit_on_error
	for c in *
	do
		if [ -f $c -a -x $c ]
		then
			echo "$c"
		fi
	done
	restore_exit_on_error
}

#
# convert_to_bytes -- converts the string with K, M, G or T suffixes
# to bytes
#
# example:
#   "1G" --> "1073741824"
#   "2T" --> "2199023255552"
#   "3k" --> "3072"
#   "1K" --> "1024"
#   "10" --> "10"
#
function convert_to_bytes() {
	size="$(echo $1 | tr '[:upper:]' '[:lower:]')"
	if [[ $size == *kib ]]
	then size=$(($(echo $size | tr -d 'kib') * 1024))
	elif [[ $size == *mib ]]
	then size=$(($(echo $size | tr -d 'mib') * 1024 * 1024))
	elif [[ $size == *gib ]]
	then size=$(($(echo $size | tr -d 'gib') * 1024 * 1024 * 1024))
	elif [[ $size == *tib ]]
	then size=$(($(echo $size | tr -d 'tib') * 1024 * 1024 * 1024 * 1024))
	elif [[ $size == *pib ]]
	then size=$(($(echo $size | tr -d 'pib') * 1024 * 1024 * 1024 * 1024 * 1024))
	elif [[ $size == *kb ]]
	then size=$(($(echo $size | tr -d 'kb') * 1000))
	elif [[ $size == *mb ]]
	then size=$(($(echo $size | tr -d 'mb') * 1000 * 1000))
	elif [[ $size == *gb ]]
	then size=$(($(echo $size | tr -d 'gb') * 1000 * 1000 * 1000))
	elif [[ $size == *tb ]]
	then size=$(($(echo $size | tr -d 'tb') * 1000 * 1000 * 1000 * 1000))
	elif [[ $size == *pb ]]
	then size=$(($(echo $size | tr -d 'pb') * 1000 * 1000 * 1000 * 1000 * 1000))
	elif [[ $size == *b ]]
	then size=$(($(echo $size | tr -d 'b')))
	elif [[ $size == *k ]]
	then size=$(($(echo $size | tr -d 'k') * 1024))
	elif [[ $size == *m ]]
	then size=$(($(echo $size | tr -d 'm') * 1024 * 1024))
	elif [[ $size == *g ]]
	then size=$(($(echo $size | tr -d 'g') * 1024 * 1024 * 1024))
	elif [[ $size == *t ]]
	then size=$(($(echo $size | tr -d 't') * 1024 * 1024 * 1024 * 1024))
	elif [[ $size == *p ]]
	then size=$(($(echo $size | tr -d 'p') * 1024 * 1024 * 1024 * 1024 * 1024))
	fi

	echo "$size"
}

#
# create_file -- create zeroed out files of a given length
#
# example, to create two files, each 1GB in size:
#	create_file 1G testfile1 testfile2
#
function create_file() {
	size=$(convert_to_bytes $1)
	shift
	for file in $*
	do
		$DD if=/dev/zero of=$file bs=1M count=$size iflag=count_bytes >> $PREP_LOG_FILE
	done
}

#
# create_nonzeroed_file -- create non-zeroed files of a given length
#
# A given first kilobytes of the file is zeroed out.
#
# example, to create two files, each 1GB in size, with first 4K zeroed
#	create_nonzeroed_file 1G 4K testfile1 testfile2
#
function create_nonzeroed_file() {
	offset=$(convert_to_bytes $2)
	size=$(($(convert_to_bytes $1) - $offset))
	shift 2
	for file in $*
	do
		truncate -s ${offset} $file >> $PREP_LOG_FILE
		$DD if=/dev/zero bs=1K count=${size} iflag=count_bytes 2>>$PREP_LOG_FILE | tr '\0' '\132' >> $file
	done
}

#
# create_holey_file -- create holey files of a given length
#
# examples:
#	create_holey_file 1024k testfile1 testfile2
#	create_holey_file 2048M testfile1 testfile2
#	create_holey_file 234 testfile1
#	create_holey_file 2340b testfile1
#
# Input unit size is in bytes with optional suffixes like k, KB, M, etc.
#

function create_holey_file() {
	size=$(convert_to_bytes $1)
	shift
	for file in $*
	do
		truncate -s ${size} $file >> $PREP_LOG_FILE
	done
}

#
# create_poolset -- create a dummy pool set
#
# Creates a pool set file using the provided list of part sizes and paths.
# Optionally, it also creates the selected part files (zeroed, partially zeroed
# or non-zeroed) with requested size and mode.  The actual file size may be
# different than the part size in the pool set file.
# 'r' or 'R' on the list of arguments indicate the beginning of the next
# replica set and 'm' or 'M' the beginning of the next remote replica set.
# 'o' or 'O' indicates the next argument is a pool set option.
# A remote replica requires two parameters: a target node and a pool set
# descriptor.
#
# Each part argument has the following format:
#   psize:ppath[:cmd[:fsize[:mode]]]
#
# where:
#   psize - part size or AUTO (only for DAX device)
#   ppath - path
#   cmd   - (optional) can be:
#            x - do nothing (may be skipped if there's no 'fsize', 'mode')
#            z - create zeroed (holey) file
#            n - create non-zeroed file
#            h - create non-zeroed file, but with zeroed header (first 4KB)
#            d - create directory
#   fsize - (optional) the actual size of the part file (if 'cmd' is not 'x')
#   mode  - (optional) same format as for 'chmod' command
#
# Each remote replica argument has the following format:
#   node:desc
#
# where:
#   node - target node
#   desc - pool set descriptor
#
# example:
#   The following command define a pool set consisting of two parts: 16MB
#   and 32MB, a local replica with only one part of 48MB and a remote replica.
#   The first part file is not created, the second is zeroed.  The only replica
#   part is non-zeroed. Also, the last file is read-only and its size
#   does not match the information from pool set file. The last line describes
#   a remote replica.
#
#	create_poolset ./pool.set 16M:testfile1 32M:testfile2:z \
#				R 48M:testfile3:n:11M:0400 \
#				M remote_node:remote_pool.set \
#                               O NOHDRS
#
function create_poolset() {
	psfile=$1
	shift 1
	echo "PMEMPOOLSET" > $psfile
	while [ "$1" ]
	do
		if [ "$1" = "M" ] || [ "$1" = "m" ] # remote replica
		then
			shift 1

			cmd=$1
			shift 1

			# extract last ":" separated segment as descriptor
			# extract everything before last ":" as node address
			# this extraction method is compatible with IPv6 and IPv4
			node=${cmd%:*}
			desc=${cmd##*:}

			echo "REPLICA $node $desc" >> $psfile
			continue
		fi

		if [ "$1" = "R" ] || [ "$1" = "r" ]
		then
			echo "REPLICA" >> $psfile
			shift 1
			continue
		fi

		if [ "$1" = "O" ] || [ "$1" = "o" ]
		then
			echo "OPTION $2" >> $psfile
			shift 2
			continue
		fi

		cmd=$1
		fparms=(${cmd//:/ })
		shift 1

		fsize=${fparms[0]}
		fpath=${fparms[1]}
		cmd=${fparms[2]}
		asize=${fparms[3]}
		mode=${fparms[4]}

		if [ ! $asize ]; then
			asize=$fsize
		fi

		if [ "$asize" != "AUTO" ]; then
			asize=$(convert_to_bytes $asize)
		fi

		case "$cmd"
		in
		x)
			# do nothing
			;;
		z)
			# zeroed (holey) file
			truncate -s $asize $fpath >> $PREP_LOG_FILE
			;;
		n)
			# non-zeroed file
			$DD if=/dev/zero bs=$asize count=1 2>>$PREP_LOG_FILE | tr '\0' '\132' >> $fpath
			;;
		h)
			# non-zeroed file, except 4K header
			truncate -s 4K $fpath >> prep$UNITTEST_NUM.log
			$DD if=/dev/zero bs=$asize count=1 2>>$PREP_LOG_FILE | tr '\0' '\132' >> $fpath
			truncate -s $asize $fpath >> $PREP_LOG_FILE
			;;
		d)
			mkdir -p $fpath
			;;
		esac

		if [ $mode ]; then
			chmod $mode $fpath
		fi

		echo "$fsize $fpath" >> $psfile
	done
}

function dump_last_n_lines() {
	if [ "$1" != "" -a -f "$1" ]; then
		ln=`wc -l < $1`
		if [ $ln -gt $UT_DUMP_LINES ]; then
			echo -e "Last $UT_DUMP_LINES lines of $1 below (whole file has $ln lines)." >&2
			ln=$UT_DUMP_LINES
		else
			echo -e "$1 below." >&2
		fi
		paste -d " " <(yes $UNITTEST_NAME $1 | head -n $ln) <(tail -n $ln $1) >&2
		echo >&2
	fi
}

# https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=810295
# https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=780173
# https://bugs.kde.org/show_bug.cgi?id=303877
function ignore_debug_info_errors() {
	cat $1 | grep -v \
		-e "WARNING: Serious error when reading debug info" \
		-e "When reading debug info from " \
		-e "Ignoring non-Dwarf2/3/4 block in .debug_info" \
		-e "Last block truncated in .debug_info; ignoring" \
		-e "parse_CU_Header: is neither DWARF2 nor DWARF3 nor DWARF4" \
		>  $1.tmp
	mv $1.tmp $1
}

#
# get_trace -- return tracing tool command line if applicable
#	usage: get_trace <check type> <log file> [<node>]
#
function get_trace() {
	if [ "$1" == "none" ]; then
		echo "$TRACE"
		return
	fi
	local exe=$VALGRINDEXE
	local check_type=$1
	local log_file=$2
	local opts="$VALGRIND_OPTS"
	local node=-1
	[ "$#" -eq 3 ] && node=$3

	if [ "$check_type" = "memcheck" -a "$MEMCHECK_DONT_CHECK_LEAKS" != "1" ]; then
		opts="$opts --leak-check=full"
	fi
	opts="$opts $VALGRIND_SUPP"
	if [ "$node" -ne -1 ]; then
		exe=${NODE_VALGRINDEXE[$node]}
		opts="$opts"
	fi

	echo "$exe --tool=$check_type --log-file=$log_file $opts $TRACE"
	return
}

#
# validate_valgrind_log -- validate valgrind log
#	usage: validate_valgrind_log <log-file>
#
function validate_valgrind_log() {
	[ "$VALIDATE_VALGRIND_LOG" != "1" ] && return
	if [ ! -e "$1.match" ] && grep "ERROR SUMMARY: [^0]" $1 >/dev/null; then
		msg="failed"
		[ -t 2 ] && command -v tput >/dev/null && msg="$(tput setaf 1)$msg$(tput sgr0)"
		echo -e "$UNITTEST_NAME $msg with Valgrind. See $1. First 20 lines below." >&2
		paste -d " " <(yes $UNITTEST_NAME $1 | head -n 20) <(tail -n 20 $1) >&2
		false
	fi
}

#
# expect_normal_exit -- run a given command, expect it to exit 0
#
function expect_normal_exit() {
	local VALGRIND_LOG_FILE=${CHECK_TYPE}${UNITTEST_NUM}.log
	local N=$2

	# in case of a remote execution disable valgrind check if valgrind is not
	# enabled on node
	local _CHECK_TYPE=$CHECK_TYPE
	if [ "$1" == "run_on_node" -o "$1" == "run_on_node_background" ]; then
		if [ -z $(is_valgrind_enabled_on_node $N) ]; then
			_CHECK_TYPE="none"
		fi
	else
		N=-1
	fi

	if [ -n "$TRACE" ]; then
		case "$1"
		in
		*_on_node*)
			msg "$UNITTEST_NAME: SKIP: TRACE is not supported if test is executed on remote nodes"
			exit 0
		esac
	fi

	local trace=$(get_trace $_CHECK_TYPE $VALGRIND_LOG_FILE $N)

	if [ "$MEMCHECK_DONT_CHECK_LEAKS" = "1" -a "$CHECK_TYPE" = "memcheck" ]; then
		export OLD_ASAN_OPTIONS="${ASAN_OPTIONS}"
		export ASAN_OPTIONS="detect_leaks=0 ${ASAN_OPTIONS}"
	fi

	# in case of preloading libvmmalloc.so force valgrind to not override malloc
	if [ -n "$VALGRINDEXE" -a -n "$TEST_LD_PRELOAD" ]; then
		if [ $(valgrind_version) -ge 312 ]; then
			preload=`basename $TEST_LD_PRELOAD`
		fi
		if [ "$preload" == "libvmmalloc.so" ]; then
			export VALGRIND_OPTS="$VALGRIND_OPTS --soname-synonyms=somalloc=nouserintercepts"
		fi
	fi

	local REMOTE_VALGRIND_LOG=0
	if [ "$CHECK_TYPE" != "none" ]; then
	        case "$1"
	        in
	        run_on_node)
			REMOTE_VALGRIND_LOG=1
			trace="$1 $2 $trace"
			[ $# -ge 2  ] && shift 2 || shift $#
	                ;;
	        run_on_node_background)
			trace="$1 $2 $3 $trace"
			[ $# -ge 3  ] && shift 3 || shift $#
	                ;;
	        wait_on_node|wait_on_node_port|kill_on_node)
			[ "$1" = "wait_on_node" ] && REMOTE_VALGRIND_LOG=1
			trace="$1 $2 $3 $4"
			[ $# -ge 4  ] && shift 4 || shift $#
	                ;;
	        esac
	fi

	if [ "$CHECK_TYPE" = "drd" ]; then
		export VALGRIND_OPTS="$VALGRIND_OPTS --suppressions=../drd-log.supp"
	fi

	disable_exit_on_error

	eval $ECHO LD_LIBRARY_PATH=$TEST_LD_LIBRARY_PATH LD_PRELOAD=$TEST_LD_PRELOAD \
		$trace $*
	ret=$?

	if [ $REMOTE_VALGRIND_LOG -eq 1 ]; then
		for node in $CHECK_NODES
		do
			local new_log_file=node\_$node\_$VALGRIND_LOG_FILE
			copy_files_from_node $node "." ${NODE_TEST_DIR[$node]}/$VALGRIND_LOG_FILE
			mv $VALGRIND_LOG_FILE $new_log_file
		done
	fi
	restore_exit_on_error

	if [ "$ret" -ne "0" ]; then
		if [ "$ret" -gt "128" ]; then
			msg="crashed (signal $(($ret - 128)))"
		else
			msg="failed with exit code $ret"
		fi
		[ -t 2 ] && command -v tput >/dev/null && msg="$(tput setaf 1)$msg$(tput sgr0)"

		if [ -f $ERR_LOG_FILE ]; then
			if [ "$UNITTEST_LOG_LEVEL" -ge "1" ]; then
				echo -e "$UNITTEST_NAME $msg. $ERR_LOG_FILE below." >&2
				cat $ERR_LOG_FILE >&2
			else
				echo -e "$UNITTEST_NAME $msg. $ERR_LOG_FILE above." >&2
			fi
		else
			echo -e "$UNITTEST_NAME $msg." >&2
		fi
		if [ "$CHECK_TYPE" != "none" -a -f $VALGRIND_LOG_FILE ]; then
			dump_last_n_lines $VALGRIND_LOG_FILE
		fi

		# ignore Ctrl-C
		if [ $ret != 130 ]; then
			for f in $(get_files "node_.*${UNITTEST_NUM}\.log"); do
				dump_last_n_lines $f
			done

			dump_last_n_lines $TRACE_LOG_FILE
			dump_last_n_lines $PMEM_LOG_FILE
			dump_last_n_lines $PMEMOBJ_LOG_FILE
			dump_last_n_lines $PMEMLOG_LOG_FILE
			dump_last_n_lines $PMEMBLK_LOG_FILE
			dump_last_n_lines $PMEMCTO_LOG_FILE
			dump_last_n_lines $PMEMPOOL_LOG_FILE
			dump_last_n_lines $VMEM_LOG_FILE
			dump_last_n_lines $VMMALLOC_LOG_FILE
			dump_last_n_lines $RPMEM_LOG_FILE
			dump_last_n_lines $RPMEMD_LOG_FILE
		fi

		[ $NODES_MAX -ge 0 ] && clean_all_remote_nodes

		false
	fi
	if [ "$CHECK_TYPE" != "none" ]; then
		if [ $REMOTE_VALGRIND_LOG -eq 1 ]; then
			for node in $CHECK_NODES
			do
				local log_file=node\_$node\_$VALGRIND_LOG_FILE
				ignore_debug_info_errors $new_log_file
				validate_valgrind_log $new_log_file
			done
		else
			if [ -f $VALGRIND_LOG_FILE ]; then
				ignore_debug_info_errors $VALGRIND_LOG_FILE
				validate_valgrind_log $VALGRIND_LOG_FILE
			fi
		fi
	fi

	if [ "$MEMCHECK_DONT_CHECK_LEAKS" = "1" -a "$CHECK_TYPE" = "memcheck" ]; then
		export ASAN_OPTIONS="${OLD_ASAN_OPTIONS}"
	fi
}

#
# expect_abnormal_exit -- run a given command, expect it to exit non-zero
#
function expect_abnormal_exit() {
	if [ -n "$TRACE" ]; then
		case "$1"
		in
		*_on_node*)
			msg "$UNITTEST_NAME: SKIP: TRACE is not supported if test is executed on remote nodes"
			exit 0
		esac
	fi

	# in case of preloading libvmmalloc.so force valgrind to not override malloc
	if [ -n "$VALGRINDEXE" -a -n "$TEST_LD_PRELOAD" ]; then
		if [ $(valgrind_version) -ge 312 ]; then
			preload=`basename $TEST_LD_PRELOAD`
		fi
		if [ "$preload" == "libvmmalloc.so" ]; then
			export VALGRIND_OPTS="$VALGRIND_OPTS --soname-synonyms=somalloc=nouserintercepts"
		fi
	fi

	if [ "$CHECK_TYPE" = "drd" ]; then
		export VALGRIND_OPTS="$VALGRIND_OPTS --suppressions=../drd-log.supp"
	fi

	disable_exit_on_error
	eval $ECHO ASAN_OPTIONS="detect_leaks=0 ${ASAN_OPTIONS}" \
		LD_LIBRARY_PATH=$TEST_LD_LIBRARY_PATH LD_PRELOAD=$TEST_LD_PRELOAD $TRACE $*
	ret=$?
	restore_exit_on_error

	if [ "$ret" -eq "0" ]; then
		msg="succeeded"
		[ -t 2 ] && command -v tput >/dev/null && msg="$(tput setaf 1)$msg$(tput sgr0)"

		echo -e "$UNITTEST_NAME command $msg unexpectedly." >&2

		[ $NODES_MAX -ge 0 ] && clean_all_remote_nodes

		false
	fi
}

#
# check_pool -- run pmempool check on specified pool file
#
function check_pool() {
	if [ "$CHECK_POOL" == "1" ]
	then
		if [ "$VERBOSE" != "0" ]
		then
			echo "$UNITTEST_NAME: checking consistency of pool ${1}"
		fi
		${PMEMPOOL}.static-nondebug check $1 2>&1 1>>$CHECK_POOL_LOG_FILE
	fi
}

#
# check_pools -- run pmempool check on specified pool files
#
function check_pools() {
	if [ "$CHECK_POOL" == "1" ]
	then
		for f in $*
		do
			check_pool $f
		done
	fi
}

#
# require_unlimited_vm -- require unlimited virtual memory
#
# This implies requirements for:
# - overcommit_memory enabled (/proc/sys/vm/overcommit_memory is 0 or 1)
# - unlimited virtual memory (ulimit -v is unlimited)
#
function require_unlimited_vm() {
	$VM_OVERCOMMIT && [ $(ulimit -v) = "unlimited" ] && return
	msg "$UNITTEST_NAME: SKIP required: overcommit_memory enabled and unlimited virtual memory"
	exit 0
}

#
# require_no_superuser -- require user without superuser rights
#
function require_no_superuser() {
	local user_id=$(id -u)
	[ "$user_id" != "0" ] && return
	msg "$UNITTEST_NAME: SKIP required: run without superuser rights"
	exit 0
}

#
# require_no_freebsd -- Skip test on FreeBSD
#
function require_no_freebsd() {
	[ "$(uname -s)" != "FreeBSD" ] && return
	msg "$UNITTEST_NAME: SKIP: Not supported on FreeBSD"
	exit 0
}

#
# require_procfs -- Skip test if /proc is not mounted
#
function require_procfs() {
	mount | grep -q "/proc" && return
	msg "$UNITTEST_NAME: SKIP: /proc not mounted"
	exit 0
}

#
# require_test_type -- only allow script to continue for a certain test type
#
function require_test_type() {
	req_test_type=1
	for type in $*
	do
		case "$TEST"
		in
		all)
			# "all" is a synonym of "short + medium + long"
			return
			;;
		check)
			# "check" is a synonym of "short + medium"
			[ "$type" = "short" -o "$type" = "medium" ] && return
			;;
		*)
			[ "$type" = "$TEST" ] && return
			;;
		esac
	done
	verbose_msg "$UNITTEST_NAME: SKIP test-type $TEST ($* required)"
	exit 0
}

#
# require_pmem -- only allow script to continue for a real PMEM device
#
function require_pmem() {
	[ $PMEM_IS_PMEM -eq 0 ] && return
	fatal "error: PMEM_FS_DIR=$PMEM_FS_DIR does not point to a PMEM device"
}

#
# require_non_pmem -- only allow script to continue for a non-PMEM device
#
function require_non_pmem() {
	[ $NON_PMEM_IS_PMEM -ne 0 ] && return
	fatal "error: NON_PMEM_FS_DIR=$NON_PMEM_FS_DIR does not point to a non-PMEM device"
}

#
# lock_devdax -- acquire a lock on Device DAXes
#
lock_devdax() {
	exec {DEVDAX_LOCK_FD}> $DEVDAX_LOCK
	flock $DEVDAX_LOCK_FD
}

#
# unlock_devdax -- release a lock on Device DAXes
#
unlock_devdax() {
	flock -u $DEVDAX_LOCK_FD
	eval "exec ${DEVDAX_LOCK_FD}>&-"
}

#
# require_dev_dax_node -- common function for require_dax_devices and
# node_require_dax_device
#
# usage: require_dev_dax_node <N devices> [<node>]
#
function require_dev_dax_node() {
	req_dax_dev=1
	if  [ "$req_dax_dev_align" == "1" ]; then
		fatal "$UNITTEST_NAME: Do not use 'require_(node_)dax_devices' and "
			"'require_(node_)dax_device_alignments' together. Use the latter instead."
	fi

	local min=$1
	local node=$2
	if [ -n "$node" ]; then
		local DIR=${NODE_WORKING_DIR[$node]}/$curtestdir
		local prefix="$UNITTEST_NAME: SKIP NODE $node:"
		local device_dax_path=(${NODE_DEVICE_DAX_PATH[$node]})
		if [  ${#device_dax_path[@]} -lt $min ]; then
			msg "$prefix NODE_${node}_DEVICE_DAX_PATH does not specify enough dax devices (min: $min)"
			exit 0
		fi
		local cmd="ssh $SSH_OPTS ${NODE[$node]} cd $DIR && LD_LIBRARY_PATH=$REMOTE_LD_LIBRARY_PATH ../pmemdetect -d"
	else
		local prefix="$UNITTEST_NAME: SKIP"
		if [ ${#DEVICE_DAX_PATH[@]} -lt $min ]; then
			msg "$prefix DEVICE_DAX_PATH does not specify enough dax devices (min: $min)"
			exit 0
		fi
		local device_dax_path=${DEVICE_DAX_PATH[@]}
		local cmd="$PMEMDETECT -d"
	fi

	for path in ${device_dax_path[@]}
	do
		disable_exit_on_error
		out=$($cmd $path 2>&1)
		ret=$?
		restore_exit_on_error

		if [ "$ret" == "0" ]; then
			continue
		elif [ "$ret" == "1" ]; then
			msg "$prefix $out"
			exit 0
		else
			fatal "$UNITTEST_NAME: pmemdetect: $out"
		fi
	done
	DEVDAX_TO_LOCK=1
}

#
# require_dax_devices -- only allow script to continue if there is a required
# number of Device DAX devices
#
function require_dax_devices() {
	require_dev_dax_node $1
}

#
# require_node_dax_device -- only allow script to continue if specified node
# has enough Device DAX devices defined in testconfig.sh
#
function require_node_dax_device() {
	validate_node_number $1
	require_dev_dax_node $2 $1
}

#
# get_node_devdax_path -- get path of a Device DAX device on a node
#
# usage: get_node_devdax_path <node> <device>
#
get_node_devdax_path() {
	local node=$1
	local device=$2
	local device_dax_path=(${NODE_DEVICE_DAX_PATH[$node]})
	echo ${device_dax_path[$device]}
}

#
# dax_device_zero -- zero all local dax devices
#
dax_device_zero() {
	for path in ${DEVICE_DAX_PATH[@]}
	do
		${PMEMPOOL}.static-debug rm -f $path
	done
}

#
# node_dax_device_zero -- zero all dax devices on a node
#
node_dax_device_zero() {
	local node=$1
	local DIR=${NODE_WORKING_DIR[$node]}/$curtestdir
	local prefix="$UNITTEST_NAME: SKIP NODE $node:"
	local device_dax_path=(${NODE_DEVICE_DAX_PATH[$node]})
	local cmd="ssh $SSH_OPTS ${NODE[$node]} cd $DIR && LD_LIBRARY_PATH=$REMOTE_LD_LIBRARY_PATH ../pmempool rm -f"

	for path in ${device_dax_path[@]}
	do
		disable_exit_on_error
		out=$($cmd $path 2>&1)
		ret=$?
		restore_exit_on_error

		if [ "$ret" == "0" ]; then
			continue
		elif [ "$ret" == "1" ]; then
			msg "$prefix $out"
			exit 0
		else
			fatal "$UNITTEST_NAME: pmempool rm: $out"
		fi
	done

}

#
# get_devdax_size -- get the size of a device dax
#
function get_devdax_size() {
	local device=$1
	local path=${DEVICE_DAX_PATH[$device]}
	local major_hex=$(stat -c "%t" $path)
	local minor_hex=$(stat -c "%T" $path)
	local major_dec=$((16#$major_hex))
	local minor_dec=$((16#$minor_hex))
	cat /sys/dev/char/$major_dec:$minor_dec/size
}

#
# get_node_devdax_size -- get the size of a device dax on a node
#
function get_node_devdax_size() {
	local node=$1
	local device=$2
	local device_dax_path=(${NODE_DEVICE_DAX_PATH[$node]})
	local path=${device_dax_path[$device]}
	local cmd_prefix="ssh $SSH_OPTS ${NODE[$node]} "

	disable_exit_on_error
	out=$($cmd_prefix stat -c %t $path 2>&1)
	ret=$?
	restore_exit_on_error
	if [ "$ret" != "0" ]; then
		fatal "UNITTEST_NAME: stat on node $node: $out"
	fi
	local major=$((16#$out))

	disable_exit_on_error
	out=$($cmd_prefix stat -c %T $path 2>&1)
	ret=$?
	restore_exit_on_error
	if [ "$ret" != "0" ]; then
		fatal "$UNITTEST_NAME: stat on node $node: $out"
	fi
	local minor=$((16#$out))

	disable_exit_on_error
	out=$($cmd_prefix "cat /sys/dev/char/$major:$minor/size" 2>&1)
	ret=$?
	restore_exit_on_error
	if [ "$ret" != "0" ]; then
		fatal "$UNITTEST_NAME: stat on node $node: $out"
	fi
	echo $out
}

#
# dax_get_alignment -- get the alignment of a device dax
#
function dax_get_alignment() {
	major_hex=$(stat -c "%t" $1)
	minor_hex=$(stat -c "%T" $1)
	major_dec=$((16#$major_hex))
	minor_dec=$((16#$minor_hex))
	cat /sys/dev/char/$major_dec:$minor_dec/device/align
}


#
# require_dax_device_node_alignments -- only allow script to continue if
#    the internal Device DAX alignments on a remote nodes are as specified.
# If necessary, it sorts DEVICE_DAX_PATH entries to match
# the requested alignment order.
#
# usage: require_node_dax_device_alignments <node> <alignment1> [ alignment2 ... ]
#
function require_node_dax_device_alignments() {
	req_dax_dev_align=1
	if  [ "$req_dax_dev" == "$1" ]; then
		fatal "$UNITTEST_NAME: Do not use 'require_(node_)dax_devices' and "
			"'require_(node_)dax_device_alignments' together. Use the latter instead."
	fi

	local node=$1
	shift

	if [ "$node" == "-1" ]; then
		local device_dax_path=(${DEVICE_DAX_PATH[@]})
		local cmd="$PMEMDETECT -a"
	else
		local device_dax_path=(${NODE_DEVICE_DAX_PATH[$node]})
		local DIR=${NODE_WORKING_DIR[$node]}/$curtestdir
		local cmd="ssh $SSH_OPTS ${NODE[$node]} cd $DIR && LD_LIBRARY_PATH=$REMOTE_LD_LIBRARY_PATH ../pmemdetect -a"
	fi

	local cnt=${#device_dax_path[@]}
	local j=0

	for alignment in $*
	do
		for (( i=j; i<cnt; i++ ))
		do
			path=${device_dax_path[$i]}

			disable_exit_on_error
			out=$($cmd $alignment $path 2>&1)
			ret=$?
			restore_exit_on_error

			if [ "$ret" == "0" ]; then
				if [ $i -ne $j ]; then
					# swap device paths
					tmp=${device_dax_path[$j]}
					device_dax_path[$j]=$path
					device_dax_path[$i]=$tmp
					if [ "$node" == "-1" ]; then
						DEVICE_DAX_PATH=(${device_dax_path[@]})
					else
						NODE_DEVICE_DAX_PATH[$node]=${device_dax_path[@]}
					fi
				fi
				break
			fi
		done

		if [ $i -eq $cnt ]; then
			if [ "$node" == "-1" ]; then
				msg "$UNITTEST_NAME: SKIP DEVICE_DAX_PATH"\
					"does not specify enough dax devices or they don't have required alignments (min: $#, alignments: $*)"
			else
				msg "$UNITTEST_NAME: SKIP NODE $node: NODE_${node}_DEVICE_DAX_PATHi"\
					"does not specify enough dax devices or they don't have required alignments (min: $#, alignments: $*)"
			fi
			exit 0
		fi

		j=$(( j + 1 ))
	done
}

#
# require_dax_device_alignments -- only allow script to continue if
#    the internal Device DAX alignments are as specified.
# If necessary, it sorts DEVICE_DAX_PATH entries to match
# the requested alignment order.
#
# usage: require_dax_device_alignments alignment1 [ alignment2 ... ]
#
require_dax_device_alignments() {
	require_node_dax_device_alignments -1 $*
}


#
# require_fs_type -- only allow script to continue for a certain fs type
#
function require_fs_type() {
	req_fs_type=1
	for type in $*
	do
		# treat any as either pmem or non-pmem
		[ "$type" = "$FS" ] ||
			([ -n "${FORCE_FS:+x}" ] && [ "$type" = "any" ] &&
			[ "$FS" != "none" ]) &&
		case "$REAL_FS"
		in
		pmem)
			require_pmem && return
			;;
		non-pmem)
			require_non_pmem && return
			;;
		none)
			return
			;;
		esac
	done
	verbose_msg "$UNITTEST_NAME: SKIP fs-type $FS ($* required)"
	exit 0
}

#
# require_build_type -- only allow script to continue for a certain build type
#
function require_build_type() {
	for type in $*
	do
		[ "$type" = "$BUILD" ] && return
	done
	verbose_msg "$UNITTEST_NAME: SKIP build-type $BUILD ($* required)"
	exit 0
}

#
# require_command -- only allow script to continue if specified command exists
#
function require_command() {
	if ! command -pv $1 1>/dev/null
	then
		msg "$UNITTEST_NAME: SKIP: '$1' command required"
		exit 0
	fi
}

#
# require_pkg -- only allow script to continue if specified package exists
#    usage: require_pkg <package name> [<package minimal version>]
#
function require_pkg() {
	if ! command -v pkg-config 1>/dev/null
	then
		msg "$UNITTEST_NAME: SKIP pkg-config required"
		exit 0
	fi

	local COMMAND="pkg-config $1"
	local MSG="$UNITTEST_NAME: SKIP '$1' package"
	if [ "$#" -eq "2" ]; then
		COMMAND="$COMMAND --atleast-version $2"
		MSG="$MSG (version >= $2)"
	fi
	MSG="$MSG required"
	if ! $COMMAND
	then
		msg "$MSG"
		exit 0
	fi
}

#
# require_node_pkg -- only allow script to continue if specified package exists
# on specified node
#    usage: require_node_pkg <node> <package name> [<package minimal version>]
#
function require_node_pkg() {
	validate_node_number $1

	local N=$1
	shift

	local DIR=${NODE_WORKING_DIR[$N]}/$curtestdir
	local COMMAND="${NODE_ENV[$N]}"
	if [ -n "${NODE_LD_LIBRARY_PATH[$N]}" ]; then
		local PKG_CONFIG_PATH=${NODE_LD_LIBRARY_PATH[$N]//:/\/pkgconfig:}/pkgconfig
		COMMAND="$COMMAND PKG_CONFIG_PATH=\$PKG_CONFIG_PATH:$PKG_CONFIG_PATH"
	fi

	COMMAND="$COMMAND pkg-config $1"
	MSG="$UNITTEST_NAME: SKIP NODE $N: '$1' package"
	if [ "$#" -eq "2" ]; then
		COMMAND="$COMMAND --atleast-version $2"
		MSG="$MSG (version >= $2)"
	fi
	MSG="$MSG required"

	disable_exit_on_error
	run_command ssh $SSH_OPTS ${NODE[$N]} "$COMMAND" 2>&1
	ret=$?
	restore_exit_on_error

	if [ "$ret" == 1 ]; then
		msg "$MSG"
		exit 0
	fi
}

#
# configure_valgrind -- only allow script to continue when settings match
#
function configure_valgrind() {
	case "$1"
	in
	memcheck|pmemcheck|helgrind|drd|force-disable)
		;;
	*)
		usage "bad test-type: $1"
		;;
	esac

	if [ "$CHECK_TYPE" == "none" ]; then
		if [ "$1" == "force-disable" ]; then
			msg "all valgrind tests disabled"
		elif [ "$2" = "force-enable" ]; then
			CHECK_TYPE="$1"
			require_valgrind_tool $1 $3
		elif [ "$2" = "force-disable" ]; then
			CHECK_TYPE=none
		else
			fatal "invalid parameter"
		fi
	else
		if [ "$1" == "force-disable" ]; then
			msg "$UNITTEST_NAME: SKIP RUNTESTS script parameter $CHECK_TYPE tries to enable valgrind test when all valgrind tests are disabled in TEST"
			exit 0
		elif [ "$CHECK_TYPE" != "$1" -a "$2" == "force-enable" ]; then
			msg "$UNITTEST_NAME: SKIP RUNTESTS script parameter $CHECK_TYPE tries to enable different valgrind test than one defined in TEST"
			exit 0
		elif [ "$CHECK_TYPE" == "$1" -a "$2" == "force-disable" ]; then
			msg "$UNITTEST_NAME: SKIP RUNTESTS script parameter $CHECK_TYPE tries to enable test defined in TEST as force-disable"
			exit 0
		fi
		require_valgrind_tool $CHECK_TYPE $3
	fi

	if [ "$UT_VALGRIND_SKIP_PRINT_MISMATCHED" == 1 ]; then
		export UT_SKIP_PRINT_MISMATCHED=1
	fi
}

#
# require_valgrind -- continue script execution only if
#	valgrind package is installed
#
function require_valgrind() {
	require_no_asan
	disable_exit_on_error
	VALGRINDEXE=`which valgrind 2>/dev/null`
	local ret=$?
	restore_exit_on_error
	if [ $ret -ne 0 ]; then
		msg "$UNITTEST_NAME: SKIP valgrind package required"
		exit 0
	fi
	[ $NODES_MAX -lt 0 ] && return;
	for N in $NODES_SEQ; do
		if [ "${NODE_VALGRINDEXE[$N]}" = "" ]; then
			disable_exit_on_error
			NODE_VALGRINDEXE[$N]=$(ssh $SSH_OPTS ${NODE[$N]} "which valgrind 2>/dev/null")
			ret=$?
			restore_exit_on_error
			if [ $ret -ne 0 ]; then
				msg "$UNITTEST_NAME: SKIP valgrind package required on remote node #$N"
				exit 0
			fi
		fi
	done
}

#
# require_valgrind_tool -- continue script execution only if valgrind with
#	specified tool is installed
#
#	usage: require_valgrind_tool <tool> [<binary>]
#
function require_valgrind_tool() {
	require_valgrind
	local tool=$1
	local binary=$2
	local dir=.
	[ -d "$2" ] && dir="$2" && binary=
	pushd "$dir" > /dev/null
	[ -n "$binary" ] || binary=$(get_executables)
	if [ -z "$binary" ]; then
		fatal "require_valgrind_tool: error: no binary found"
	fi
	strings ${binary} 2>&1 | \
	grep -q "compiled with support for Valgrind $tool" && true
	if [ $? -ne 0 ]; then
		msg "$UNITTEST_NAME: SKIP not compiled with support for Valgrind $tool"
		exit 0
	fi

	if [ "$tool" == "pmemcheck" -o "$tool" == "helgrind" ]; then
		valgrind --tool=$tool --help 2>&1 | \
		grep -qi "$tool is Copyright (c)" && true
		if [ $? -ne 0 ]; then
			msg "$UNITTEST_NAME: SKIP valgrind package with $tool required"
			exit 0;
		fi
	fi
	popd > /dev/null
	return 0
}

#
# set_valgrind_exe_name -- set the actual Valgrind executable name
#
# On some systems (Ubuntu), "valgrind" is a shell script that calls
# the actual executable "valgrind.bin".
# The wrapper script doesn't work well with LD_PRELOAD, so we want
# to call Valgrind directly.
#
function set_valgrind_exe_name() {
	if [ "$VALGRINDEXE" = "" ]; then
		fatal "set_valgrind_exe_name: error: valgrind is not set up"
	fi

	local VALGRINDDIR=`dirname $VALGRINDEXE`
	if [ -x $VALGRINDDIR/valgrind.bin ]; then
		VALGRINDEXE=$VALGRINDDIR/valgrind.bin
	fi

	[ $NODES_MAX -lt 0 ] && return;
	for N in $NODES_SEQ; do
		local COMMAND="\
			[ -x $(dirname ${NODE_VALGRINDEXE[$N]})/valgrind.bin ] && \
			echo $(dirname ${NODE_VALGRINDEXE[$N]})/valgrind.bin || \
			echo ${NODE_VALGRINDEXE[$N]}"
		NODE_VALGRINDEXE[$N]=$(ssh $SSH_OPTS ${NODE[$N]} $COMMAND)
		if [ $? -ne 0 ]; then
			fatal ${NODE_VALGRINDEXE[$N]}
		fi
	done
}

#
# valgrind_version -- returns Valgrind version
#
function valgrind_version() {
	require_valgrind
	require_command bc
	$VALGRINDEXE --version | sed "s/valgrind-\([0-9]*\)\.\([0-9]*\).*/\1*100+\2/" | bc
}

#
# require_valgrind_dev_version -- continue script execution only if
#	certain version (or later) of valgrind-devel package is installed
#
function require_valgrind_dev_version() {
	require_valgrind
	local version=(${1//./ })
	local major=${version[0]}
	local minor=${version[1]}
	local define="VALGRIND_VERSION_${major}_${minor}_OR_LATER"

	case "$define" in
		VALGRIND_VERSION_3_7_OR_LATER)
			local code=" \
        #include <valgrind/valgrind.h>
        #if defined (VALGRIND_RESIZEINPLACE_BLOCK)
        $define
        #endif"
			;;
		*)
			local code=" \
        #include <valgrind/valgrind.h>
        #if defined (__VALGRIND_MAJOR__) && defined (__VALGRIND_MINOR__)
        #if (__VALGRIND_MAJOR__ > $major) || \
             ((__VALGRIND_MAJOR__ == $major) && (__VALGRIND_MINOR__ >= $minor))
        $define
        #endif
        #endif"
			;;
	esac
	echo "$code" | gcc ${EXTRA_CFLAGS} -E - 2>&1 | grep -q $define && return
	msg "$UNITTEST_NAME: SKIP valgrind-devel package (ver $major.$minor or later) required"
	exit 0
}

#
# require_no_asan_for - continue script execution only if passed binary does
#	NOT require libasan
#
function require_no_asan_for() {
	disable_exit_on_error
	nm $1 | grep -q __asan_
	ASAN_ENABLED=$?
	restore_exit_on_error
	if [ "$ASAN_ENABLED" == "0" ]; then
		msg "$UNITTEST_NAME: SKIP: ASAN enabled"
		exit 0
	fi
}

#
# require_cxx11 -- continue script execution only if C++11 supporting compiler
#	is installed
#
function require_cxx11() {
	[ "$CXX" ] || CXX=c++

	CXX11_AVAILABLE=`echo "int main(){return 0;}" |\
		$CXX -std=c++11 -x c++ -o /dev/null - 2>/dev/null &&\
		echo y || echo n`

	if [ "$CXX11_AVAILABLE" == "n" ]; then
		msg "$UNITTEST_NAME: SKIP: C++11 required"
		exit 0
	fi
}

#
# require_no_asan - continue script execution only if libpmem does NOT require
#	libasan
#
function require_no_asan() {
	case "$BUILD"
	in
	debug)
		require_no_asan_for ../../debug/libpmem.so
		;;
	nondebug)
		require_no_asan_for ../../nondebug/libpmem.so
		;;
	static-debug)
		require_no_asan_for ../../debug/libpmem.a
		;;
	static-nondebug)
		require_no_asan_for ../../nondebug/libpmem.a
		;;
	esac
}

#
# require_tty - continue script execution only if standard output is a terminal
#
function require_tty() {
	if ! tty >/dev/null; then
		msg "$UNITTEST_NAME: SKIP no terminal"
		exit 0
	fi
}

#
# require_binary -- continue script execution only if the binary has been compiled
#
# In case of conditional compilation, skip this test.
#
function require_binary() {
	if [ -z "$1" ]; then
		fatal "require_binary: error: binary not provided"
	fi
	if [ ! -x "$1" ]; then
		msg "$UNITTEST_NAME: SKIP no binary found"
		exit 0
	fi

	return
}

#
# require_preload - continue script execution only if supplied
#	executable does not generate SIGABRT
#
#	Used to check that LD_PRELOAD of, e.g., libvmmalloc is possible
#
#	usage: require_preload <errorstr> <executable> [<exec_args>]
#
function require_preload() {
	msg=$1
	shift
	trap SIGABRT
	disable_exit_on_error
	ret=$(LD_LIBRARY_PATH=$TEST_LD_LIBRARY_PATH LD_PRELOAD=$TEST_LD_PRELOAD $* 2>&1 /dev/null)
	ret=$?
	restore_exit_on_error
	if [ $ret == 134 ]; then
		msg "$UNITTEST_NAME: SKIP: $msg not supported"
		rm -f $1.core
		exit 0
	fi
}

#
# check_absolute_path -- continue script execution only if $DIR path is
#                        an absolute path; do not resolve symlinks
#
function check_absolute_path() {
	if [ "${DIR:0:1}" != "/" ]; then
		fatal "Directory \$DIR has to be an absolute path. $DIR was given."
	fi
}

#
# run_command -- run a command in a verbose or quiet way
#
function run_command()
{
	local COMMAND="$*"
	if [ "$VERBOSE" != "0" ]; then
		echo "$ $COMMAND"
		$COMMAND
	else
		$COMMAND
	fi
}


#
# validate_node_number -- validate a node number
#
function validate_node_number() {

	[ $1 -gt $NODES_MAX ] \
		&& fatal "error: node number ($1) greater than maximum allowed node number ($NODES_MAX)"
	return 0
}

#
# clean_remote_node -- usage: clean_remote_node <node> <list-of-pid-files>
#
function clean_remote_node() {

	validate_node_number $1

	local N=$1
	shift
	local DIR=${NODE_WORKING_DIR[$N]}/$curtestdir

	# register the list of PID files to be cleaned in case of an error
	NODE_PID_FILES[$N]="${NODE_PID_FILES[$N]} $*"

	# clean the remote node
	disable_exit_on_error
	for pidfile in ${NODE_PID_FILES[$N]}; do
		require_ctrld_err $N $pidfile
		run_command ssh $SSH_OPTS ${NODE[$N]} "\
			cd $DIR && [ -f $pidfile ] && \
			../ctrld $pidfile kill SIGINT && \
			../ctrld $pidfile wait 1 ; \
			rm -f $pidfile"
	done;
	restore_exit_on_error

	return 0
}

#
# clean_all_remote_nodes -- clean all remote nodes in case of an error
#
function clean_all_remote_nodes() {

	msg "$UNITTEST_NAME: CLEAN (cleaning processes on remote nodes)"

	local N=0
	disable_exit_on_error
	for N in $NODES_SEQ; do
		local DIR=${NODE_WORKING_DIR[$N]}/$curtestdir
		for pidfile in ${NODE_PID_FILES[$N]}; do
			run_command ssh $SSH_OPTS ${NODE[$N]} "\
				cd $DIR && [ -f $pidfile ] && \
				../ctrld $pidfile kill SIGINT && \
				../ctrld $pidfile wait 1 ; \
				rm -f $pidfile"
		done
	done
	restore_exit_on_error

	return 0
}

#
# export_vars_node -- export specified variables on specified node
#
function export_vars_node() {
	local N=$1
	shift
	validate_node_number $N
	for var in "$@"; do
		NODE_ENV[$N]="${NODE_ENV[$N]} $var=${!var}"
	done
}

#
# require_nodes_libfabric -- only allow script to continue if libfabric with
#                            optionally specified provider is available on
#                            specified node
#    usage: require_nodes_libfabric <node> <provider> [<libfabric-version>]
#
function require_node_libfabric() {
	validate_node_number $1

	local N=$1
	local provider=$2
	# Minimal required version of libfabric.
	# Keep in sync with requirements in src/common.inc.
	local version=${3:-1.4.2}

	require_pkg libfabric "$version"
	require_node_pkg $N libfabric "$version"
	if [ "$RPMEM_DISABLE_LIBIBVERBS" != "y" ]; then
		if ! fi_info --list | grep -q verbs; then
			msg "$UNITTEST_NAME: SKIP libfabric not compiled with verbs provider"
			exit 0
		fi

		if ! run_on_node $N "fi_info --list | grep -q verbs"; then
			msg "$UNITTEST_NAME: SKIP libfabric on node $N not compiled with verbs provider"
			exit 0

		fi
	fi

	local DIR=${NODE_WORKING_DIR[$N]}/$curtestdir
	local COMMAND="$COMMAND ${NODE_ENV[$N]}"
	COMMAND="$COMMAND LD_LIBRARY_PATH=\$LD_LIBRARY_PATH:$REMOTE_LD_LIBRARY_PATH:${NODE_LD_LIBRARY_PATH[$N]}"
	COMMAND="$COMMAND ../fip ${NODE_ADDR[$N]} $provider"

	disable_exit_on_error
	fip_out=$(ssh $SSH_OPTS ${NODE[$N]} "cd $DIR && $COMMAND" 2>&1)
	ret=$?
	restore_exit_on_error

	if [ "$ret" == "0" ]; then
		return
	elif [ "$ret" == "1" ]; then
		msg "$UNITTEST_NAME: SKIP NODE $N: $fip_out"
		exit 0
	else
		fatal "NODE $N: require_libfabric $provider: $fip_out"
	fi
}

#
# check_if_node_is_reachable -- check if the $1 node is reachable
#
function check_if_node_is_reachable() {
	disable_exit_on_error
	run_command ssh $SSH_OPTS ${NODE[$1]} exit
	local ret=$?
	restore_exit_on_error
	return $ret
}

#
# require_nodes -- only allow script to continue for a certain number
#                  of defined and reachable nodes
#
# Input arguments:
#   NODE[]               - (required) array of nodes' addresses
#   NODE_WORKING_DIR[]   - (required) array of nodes' working directories
#
function require_nodes() {

	local N_NODES=${#NODE[@]}
	local N=$1

	[ $N -gt $N_NODES ] \
		&& msg "$UNITTEST_NAME: SKIP: requires $N node(s), but $N_NODES node(s) provided" \
		&& exit 0

	NODES_MAX=$(($N - 1))
	NODES_SEQ=$(seq -s' ' 0 $NODES_MAX)

	# check if all required nodes are reachable
	for N in $NODES_SEQ; do
		# validate node's address
		[ "${NODE[$N]}" = "" ] \
			&& msg "$UNITTEST_NAME: SKIP: address of node #$N is not provided" \
			&& exit 0

		# validate the working directory
		[ "${NODE_WORKING_DIR[$N]}" = "" ] \
			&& fatal "error: working directory for node #$N (${NODE[$N]}) is not provided"

		# check if the node is reachable
		check_if_node_is_reachable $N
		[ $? -ne 0 ] \
			&& fatal "error: node #$N (${NODE[$N]}) is unreachable"

		# clear the list of PID files for each node
		NODE_PID_FILES[$N]=""
		NODE_TEST_DIR[$N]=${NODE_WORKING_DIR[$N]}/$curtestdir
		NODE_DIR[$N]=${NODE_WORKING_DIR[$N]}/$curtestdir/data/

		require_node_log_files $N $ERR_LOG_FILE $OUT_LOG_FILE $TRACE_LOG_FILE

		if [ "$CHECK_TYPE" != "none" -a "${NODE_VALGRINDEXE[$N]}" = "" ]; then
			disable_exit_on_error
			NODE_VALGRINDEXE[$N]=$(ssh $SSH_OPTS ${NODE[$N]} "which valgrind 2>/dev/null")
			local ret=$?
			restore_exit_on_error
			if [ $ret -ne 0 ]; then
				msg "$UNITTEST_NAME: SKIP valgrind package required on remote node #$N"
				exit 0
			fi
		fi
	done

	# remove all log files of the current unit test from the required nodes
	# and export the 'log' variables to these nodes
	for N in $NODES_SEQ; do
		for f in $(get_files "node_${N}.*${UNITTEST_NUM}\.log"); do
			rm -f $f
		done
		export_vars_node $N $REMOTE_VARS
	done

	# register function to clean all remote nodes in case of an error or SIGINT
	trap clean_all_remote_nodes ERR SIGINT

	return 0
}

#
# check_files_on_node -- check if specified files exist on given node
#
function check_files_on_node() {
	validate_node_number $1
	local N=$1
	shift
	local REMOTE_DIR=${NODE_DIR[$N]}
	run_command ssh $SSH_OPTS ${NODE[$N]} "for f in $*; do if [ ! -f $REMOTE_DIR/\$f ]; then echo \"Missing file \$f on node #$N\" 1>&2; exit 1; fi; done"
}

#
# check_no_files_on_node -- check if specified files does not exist on given node
#
function check_no_files_on_node() {
	validate_node_number $1
	local N=$1
	shift
	local REMOTE_DIR=${NODE_DIR[$N]}
	run_command ssh $SSH_OPTS ${NODE[$N]} "for f in $*; do if [ -f $REMOTE_DIR/\$f ]; then echo \"Not deleted file \$f on node #$N\" 1>&2; exit 1; fi; done"
}

#
# copy_files_to_node -- copy all required files to the given remote node
#    usage: copy_files_to_node <node> <destination dir> <file_1> [<file_2>] ...
#
function copy_files_to_node() {

	validate_node_number $1

	local N=$1
	local DEST_DIR=$2
	shift 2
	[ $# -eq 0 ] &&\
		fatal "error: copy_files_to_node(): no files provided"

	# copy all required files
	run_command scp $SCP_OPTS $@ ${NODE[$N]}:$DEST_DIR > /dev/null

	return 0
}

#
# copy_files_from_node -- copy all required files from the given remote node
#    usage: copy_files_from_node <node> <destination_dir> <file_1> [<file_2>] ...
#
function copy_files_from_node() {

	validate_node_number $1

	local N=$1
	local DEST_DIR=$2
	[ ! -d $DEST_DIR ] &&\
		fatal "error: destination directory $DEST_DIR does not exist"
	shift 2
	[ $# -eq 0 ] &&\
		fatal "error: copy_files_from_node(): no files provided"

	# compress required files, copy and extract
	local temp_file=node_${N}_temp_file.tar
	files=""
	dir_name=""

	files=$(basename -a $@)
	dir_name=$(dirname $1)
	run_command ssh $SSH_OPTS ${NODE[$N]} "cd $dir_name && tar -czf $temp_file $files"
	run_command scp $SCP_OPTS ${NODE[$N]}:$dir_name/$temp_file $DEST_DIR > /dev/null

	cd $DEST_DIR \
		&& tar -xzf $temp_file \
		&& rm $temp_file \
		&& cd - > /dev/null

	return 0
}

#
# copy_log_files -- copy log files from remote node
#
function copy_log_files() {
	local NODE_SCP_LOG_FILES[0]=""
	for N in $NODES_SEQ; do
		local DIR=${NODE_WORKING_DIR[$N]}/$curtestdir
		for file in ${NODE_LOG_FILES[$N]}; do
			NODE_SCP_LOG_FILES[$N]="${NODE_SCP_LOG_FILES[$N]} ${NODE[$N]}:$DIR/${file}"
		done
		[ "${NODE_SCP_LOG_FILES[$N]}" ] && run_command scp $SCP_OPTS ${NODE_SCP_LOG_FILES[$N]} . &> $PREP_LOG_FILE
		for file in ${NODE_LOG_FILES[$N]}; do
			[ -f $file ] && mv $file node_${N}_${file}
		done
	done
}

#
# rm_files_from_node -- removes all listed files from the given remote node
#    usage: rm_files_from_node <node> <file_1> [<file_2>] ...
#
function rm_files_from_node() {

	validate_node_number $1

	local N=$1
	shift
	[ $# -eq 0 ] &&\
		fatal "error: rm_files_from_node(): no files provided"

	run_command ssh $SSH_OPTS ${NODE[$N]} "rm -f $@"

	return 0
}

#
#
# require_node_log_files -- store log files which must be copied from
#                           specified node on failure
#
function require_node_log_files() {
	validate_node_number $1

	local N=$1
	shift

	NODE_LOG_FILES[$N]="${NODE_LOG_FILES[$N]} $*"
}

#
# require_ctrld_err -- store ctrld's log files to copy from specified
#                      node on failure
#
function require_ctrld_err() {
	local N=$1
	local PID_FILE=$2
	local DIR=${NODE_WORKING_DIR[$N]}/$curtestdir
	for cmd in run wait kill wait_port; do
		NODE_LOG_FILES[$N]="${NODE_LOG_FILES[$N]} $PID_FILE.$cmd.ctrld.log"
	done
}

#
# run_on_node -- usage: run_on_node <node> <command>
#
#                Run the <command> in background on the remote <node>.
#                LD_LIBRARY_PATH for the n-th remote node can be provided
#                in the array NODE_LD_LIBRARY_PATH[n]
#
function run_on_node() {

	validate_node_number $1

	local N=$1
	shift
	local DIR=${NODE_WORKING_DIR[$N]}/$curtestdir
	local COMMAND="UNITTEST_NUM=$UNITTEST_NUM UNITTEST_NAME=$UNITTEST_NAME"
	COMMAND="$COMMAND UNITTEST_LOG_LEVEL=1"
	COMMAND="$COMMAND ${NODE_ENV[$N]}"
	COMMAND="$COMMAND LD_LIBRARY_PATH=\$LD_LIBRARY_PATH:$REMOTE_LD_LIBRARY_PATH:${NODE_LD_LIBRARY_PATH[$N]} $*"

	run_command ssh $SSH_OPTS ${NODE[$N]} "cd $DIR && $COMMAND"
	ret=$?
	if [ "$ret" -ne "0" ]; then
		copy_log_files
	fi

	return $ret
}

#
# run_on_node_background -- usage:
#                           run_on_node_background <node> <pid-file> <command>
#
#                           Run the <command> in background on the remote <node>
#                           and create a <pid-file> for this process.
#                           LD_LIBRARY_PATH for the n-th remote node
#                           can be provided in the array NODE_LD_LIBRARY_PATH[n]
#
function run_on_node_background() {

	validate_node_number $1

	local N=$1
	local PID_FILE=$2
	shift
	shift
	local DIR=${NODE_WORKING_DIR[$N]}/$curtestdir
	local COMMAND="UNITTEST_NUM=$UNITTEST_NUM UNITTEST_NAME=$UNITTEST_NAME"
	COMMAND="$COMMAND UNITTEST_LOG_LEVEL=1"
	COMMAND="$COMMAND ${NODE_ENV[$N]}"
	COMMAND="$COMMAND LD_LIBRARY_PATH=\$LD_LIBRARY_PATH:$REMOTE_LD_LIBRARY_PATH:${NODE_LD_LIBRARY_PATH[$N]}"
	COMMAND="$COMMAND ../ctrld $PID_FILE run $RUNTEST_TIMEOUT $*"

	# register the PID file to be cleaned in case of an error
	NODE_PID_FILES[$N]="${NODE_PID_FILES[$N]} $PID_FILE"

	run_command ssh $SSH_OPTS ${NODE[$N]} "cd $DIR && $COMMAND"
	ret=$?
	if [ "$ret" -ne "0" ]; then
		copy_log_files
	fi

	return $ret
}

#
# wait_on_node -- usage: wait_on_node <node> <pid-file> [<timeout>]
#
#                 Wait until the process with the <pid-file> on the <node>
#                 exits or <timeout> expires.
#
function wait_on_node() {

	validate_node_number $1

	local N=$1
	local PID_FILE=$2
	local TIMEOUT=$3
	local DIR=${NODE_WORKING_DIR[$N]}/$curtestdir

	run_command ssh $SSH_OPTS ${NODE[$N]} "cd $DIR && ../ctrld $PID_FILE wait $TIMEOUT"
	ret=$?
	if [ "$ret" -ne "0" ]; then
		copy_log_files
	fi

	return $ret
}

#
# wait_on_node_port -- usage: wait_on_node_port <node> <pid-file> <portno>
#
#                      Wait until the process with the <pid-file> on the <node>
#                      opens the port <portno>.
#
function wait_on_node_port() {

	validate_node_number $1

	local N=$1
	local PID_FILE=$2
	local PORTNO=$3
	local DIR=${NODE_WORKING_DIR[$N]}/$curtestdir

	run_command ssh $SSH_OPTS ${NODE[$N]} "cd $DIR && ../ctrld $PID_FILE wait_port $PORTNO"
	ret=$?
	if [ "$ret" -ne "0" ]; then
		copy_log_files
	fi

	return $ret
}

#
# kill_on_node -- usage: kill_on_node <node> <pid-file> <signo>
#
#                 Send the <signo> signal to the process with the <pid-file>
#                 on the <node>.
#
function kill_on_node() {

	validate_node_number $1

	local N=$1
	local PID_FILE=$2
	local SIGNO=$3
	local DIR=${NODE_WORKING_DIR[$N]}/$curtestdir

	run_command ssh $SSH_OPTS ${NODE[$N]} "cd $DIR && ../ctrld $PID_FILE kill $SIGNO"
	ret=$?
	if [ "$ret" -ne "0" ]; then
		copy_log_files
	fi

	return $ret
}

#
# create_holey_file_on_node -- create holey files of a given length
#   usage: create_holey_file_on_node <node> <size>
#
# example, to create two files, each 1GB in size on node 0:
#	create_holey_file_on_node 0 1G testfile1 testfile2
#
# Input unit size is in bytes with optional suffixes like k, KB, M, etc.
#
function create_holey_file_on_node() {

	validate_node_number $1

	local N=$1
	size=$(convert_to_bytes $2)
	shift 2
	for file in $*
	do
		run_on_node $N truncate -s ${size} $file >> $PREP_LOG_FILE
	done
}

#
# setup -- print message that test setup is commencing
#
function setup() {
	# test type must be explicitly specified
	if [ "$req_test_type" != "1" ]; then
		fatal "error: required test type is not specified"
	fi

	# fs type "none" must be explicitly enabled
	if [ "$FS" = "none" -a "$req_fs_type" != "1" ]; then
		exit 0
	fi

	# fs type "any" must be explicitly enabled
	if [ "$FS" = "any" -a "$req_fs_type" != "1" ]; then
		exit 0
	fi

	if [ "$CHECK_TYPE" != "none" ]; then
		require_valgrind
		export VALGRIND_LOG_FILE=$CHECK_TYPE${UNITTEST_NUM}.log
		MCSTR="/$CHECK_TYPE"
	else
		MCSTR=""
	fi

	[ -n "$RPMEM_PROVIDER" ] && PROV="/$RPMEM_PROVIDER"
	[ -n "$RPMEM_PM" ] && PM="/$RPMEM_PM"

	msg "$UNITTEST_NAME: SETUP ($TEST/$REAL_FS/$BUILD$MCSTR$PROV$PM)"

	for f in $(get_files ".*[a-zA-Z_]${UNITTEST_NUM}\.log"); do
		rm -f $f
	done

	# $DIR has to be an absolute path
	check_absolute_path

	if [ "$FS" != "none" ]; then
		if [ -d "$DIR" ]; then
			rm $RM_ONEFS -rf -- $DIR
		fi

		mkdir -p $DIR
	fi
	if [ "$TM" = "1" ]; then
		start_time=$($DATE +%s.%N)
	fi

	if [ "$DEVDAX_TO_LOCK" == 1 ]; then
		lock_devdax
	fi
}

#
# check_log_empty -- if match file does not exist, assume log should be empty
#
function check_log_empty() {
	if [ ! -f ${1}.match ] && [ $(get_size $1) -ne 0 ]; then
		echo "unexpected output in $1"
		dump_last_n_lines $1
		exit 1
	fi
}

#
# check_local -- check local test results (using .match files)
#
function check_local() {
	if [ "$UT_SKIP_PRINT_MISMATCHED" == 1 ]; then
		option=-q
	fi

	check_log_empty $ERR_LOG_FILE

	FILES=$(get_files "[^0-9w]*${UNITTEST_NUM}\.log\.match")
	if [ -n "$FILES" ]; then
		../match $option $FILES
	fi
}

#
# check -- check local or remote test results (using .match files)
#
function check() {
	if [ $NODES_MAX -lt 0 ]; then
		check_local
	else
		FILES=$(get_files "node_[0-9]+_[^0-9w]*${UNITTEST_NUM}\.log\.match")

		local NODE_MATCH_FILES[0]=""
		local NODE_SCP_MATCH_FILES[0]=""
		for file in $FILES; do
			local N=`echo $file | cut -d"_" -f2`
			local DIR=${NODE_WORKING_DIR[$N]}/$curtestdir
			local FILE=`echo $file | cut -d"_" -f3 | sed "s/\.match$//g"`
			validate_node_number $N
			NODE_MATCH_FILES[$N]="${NODE_MATCH_FILES[$N]} $FILE"
			NODE_SCP_MATCH_FILES[$N]="${NODE_SCP_MATCH_FILES[$N]} ${NODE[$N]}:$DIR/$FILE"
		done

		for N in $NODES_SEQ; do
			[ "${NODE_SCP_MATCH_FILES[$N]}" ] && run_command scp $SCP_OPTS ${NODE_SCP_MATCH_FILES[$N]} . > /dev/null
			for file in ${NODE_MATCH_FILES[$N]}; do
				mv $file node_${N}_${file}
			done
		done

		if [ "$UT_SKIP_PRINT_MISMATCHED" == 1 ]; then
			option=-q
		fi

		for N in $NODES_SEQ; do
			check_log_empty node_${N}_${ERR_LOG_FILE}
		done

		if [ -n "$FILES" ]; then
			../match $option $FILES
		fi
	fi
}

#
# pass -- print message that the test has passed
#
function pass() {
	if [ "$DEVDAX_TO_LOCK" == 1 ]; then
		unlock_devdax
	fi

	if [ "$TM" = "1" ]; then
		end_time=$($DATE +%s.%N)

		start_time_sec=$($DATE -d "0 $start_time sec" +%s)
		end_time_sec=$($DATE -d "0 $end_time sec" +%s)

		days=$(((end_time_sec - start_time_sec) / (24*3600)))
		days=$(printf "%03d" $days)

		tm=$($DATE -d "0 $end_time sec - $start_time sec" +%H:%M:%S.%N)
		tm=$(echo "$days:$tm" | sed -e "s/^000://g" -e "s/^00://g" -e "s/^00://g" -e "s/\([0-9]*\)\.\([0-9][0-9][0-9]\).*/\1.\2/")
		tm="\t\t\t[$tm s]"
	else
		tm=""
	fi
	msg="PASS"
	[ -t 1 ] && command -v tput >/dev/null && msg="$(tput setaf 2)$msg$(tput sgr0)"
	if [ "$UNITTEST_LOG_LEVEL" -ge 1 ]; then
		echo -e "$UNITTEST_NAME: $msg$tm"
	fi
	if [ "$FS" != "none" ]; then
		rm $RM_ONEFS -rf -- $DIR
	fi
}

# Length of pool file's signature
SIG_LEN=8

# Offset and length of pmemobj layout
LAYOUT_OFFSET=4096
LAYOUT_LEN=1024

# Length of arena's signature
ARENA_SIG_LEN=16

# Signature of BTT Arena
ARENA_SIG="BTT_ARENA_INFO"

# Offset to first arena
ARENA_OFF=8192

#
# check_file -- check if file exists and print error message if not
#
check_file()
{
	if [ ! -f $1 ]
	then
		fatal "Missing file: ${1}"
	fi
}

#
# check_files -- check if files exist and print error message if not
#
check_files()
{
	for file in $*
	do
		check_file $file
	done
}

#
# check_no_file -- check if file has been deleted and print error message if not
#
check_no_file()
{
	if [ -f $1 ]
	then
		fatal "Not deleted file: ${1}"
	fi
}

#
# check_no_files -- check if files has been deleted and print error message if not
#
check_no_files()
{
	for file in $*
	do
		check_no_file $file
	done
}

#
# get_size -- return size of file (0 if file does not exist)
#
get_size()
{
	if [ ! -f $1 ]; then
		echo "0"
	else
		stat $STAT_SIZE $1
	fi
}

#
# get_mode -- return mode of file
#
get_mode()
{
	stat $STAT_MODE $1
}

#
# check_size -- validate file size
#
check_size()
{
	local size=$1
	local file=$2
	local file_size=$(get_size $file)

	if [[ $size != $file_size ]]
	then
		fatal "error: wrong size ${file_size} != ${size}"
	fi
}

#
# check_mode -- validate file mode
#
check_mode()
{
	local mode=$1
	local file=$2
	local file_mode=$(get_mode $file)

	if [[ $mode != $file_mode ]]
	then
		fatal "error: wrong mode ${file_mode} != ${mode}"
	fi
}

#
# check_signature -- check if file contains specified signature
#
check_signature()
{
	local sig=$1
	local file=$2
	local file_sig=$($DD if=$file bs=1 count=$SIG_LEN 2>/dev/null | tr -d \\0)

	if [[ $sig != $file_sig ]]
	then
		fatal "error: $file: signature doesn't match ${file_sig} != ${sig}"
	fi
}

#
# check_signatures -- check if multiple files contain specified signature
#
check_signatures()
{
	local sig=$1
	shift 1
	for file in $*
	do
		check_signature $sig $file
	done
}

#
# check_layout -- check if pmemobj pool contains specified layout
#
check_layout()
{
	local layout=$1
	local file=$2
	local file_layout=$($DD if=$file bs=1\
		skip=$LAYOUT_OFFSET count=$LAYOUT_LEN 2>/dev/null | tr -d \\0)

	if [[ $layout != $file_layout ]]
	then
		fatal "error: layout doesn't match ${file_layout} != ${layout}"
	fi
}

#
# check_arena -- check if file contains specified arena signature
#
check_arena()
{
	local file=$1
	local sig=$($DD if=$file bs=1 skip=$ARENA_OFF count=$ARENA_SIG_LEN 2>/dev/null | tr -d \\0)

	if [[ $sig != $ARENA_SIG ]]
	then
		fatal "error: can't find arena signature"
	fi
}

#
# dump_pool_info -- dump selected pool metadata and/or user data
#
function dump_pool_info() {
	# ignore selected header fields that differ by definition
	${PMEMPOOL}.static-nondebug info $* | sed -e "/^UUID/,/^Checksum/d"
}

#
# compare_replicas -- check replicas consistency by comparing `pmempool info` output
#
function compare_replicas() {
	disable_exit_on_error
	diff <(dump_pool_info $1 $2) <(dump_pool_info $1 $3) -I "^path" -I "^size"
	restore_exit_on_error
}

#
# get_node_dir -- returns node dir for current test
#    usage: get_node_dir <node>
#
function get_node_dir() {
	validate_node_number $1
	echo ${NODE_WORKING_DIR[$1]}/$curtestdir
}

#
# init_rpmem_on_node -- prepare rpmem environment variables on node
#    usage: init_rpmem_on_node <master-node> <slave-node-1> [<slave-node-2> ...]
#
# example:
#    The following command initialize rpmem environment variables on the node 1
#    to perform replication to the node 0 and node 2. Additionaly rpmemd pid
#    will be stored in file.pid.
#
#       init_rpmem_on_node 1 0 2:file.pid
#
function init_rpmem_on_node() {
	local master=$1
	shift

	validate_node_number $master

	case "$RPMEM_PM" in
	APM|GPSPM)
		;;
	*)
		msg "$UNITTEST_NAME: SKIP required: RPMEM_PM is invalid or empty"
		exit 0
		;;
	esac

	# Workaround for SIGSEGV in the infinipath-psm during abort
	# The infinipath-psm is registering a signal handler and do not unregister
	# it when rpmem handle is dlclosed. SIGABRT (potentially any other signal)
	# would try to call the signal handler which does not exist after dlclose.
	# Issue require a fix in the infinipath-psm or the libfabric.
	IPATH_NO_BACKTRACE=1
	export_vars_node $master IPATH_NO_BACKTRACE

	RPMEM_CMD=""
	local SEPARATOR="|"
	for slave in "$@"
	do
		slave=(${slave//:/ })
		pid=${slave[1]}
		slave=${slave[0]}

		validate_node_number $slave
		local poolset_dir=${NODE_DIR[$slave]}
		if [ -n "${RPMEM_POOLSET_DIR[$slave]}" ]; then
			poolset_dir=${RPMEM_POOLSET_DIR[$slave]}
		fi
		local trace=
		if [ -n "$(is_valgrind_enabled_on_node $slave)" ]; then
			log_file=${CHECK_TYPE}${UNITTEST_NUM}.log
			trace=$(get_trace $CHECK_TYPE $log_file $slave)
		fi
		if [ -n "$pid" ]; then
			trace="$trace ../ctrld $pid exe"
		fi
		if [ -n ${UNITTEST_DO_NOT_CHECK_OPEN_FILES+x} ]; then
			export_vars_node $slave UNITTEST_DO_NOT_CHECK_OPEN_FILES
		fi
		if [ -n ${IPATH_NO_BACKTRACE+x} ]; then
			export_vars_node $slave IPATH_NO_BACKTRACE
		fi
		CMD="cd ${NODE_TEST_DIR[$slave]} && "

		# Force pmem for APM. Otherwise in case of lack of a pmem rpmemd will
		# silently fallback to GPSPM.
		[ "$RPMEM_PM" == "APM" ] && CMD="$CMD PMEM_IS_PMEM_FORCE=1"

		CMD="$CMD ${NODE_ENV[$slave]}"
		CMD="$CMD LD_LIBRARY_PATH=\$LD_LIBRARY_PATH:$REMOTE_LD_LIBRARY_PATH:${NODE_LD_LIBRARY_PATH[$slave]}"
		CMD="$CMD $trace ../rpmemd"
		CMD="$CMD --log-file=$RPMEMD_LOG_FILE"
		CMD="$CMD --log-level=$RPMEMD_LOG_LEVEL"
		CMD="$CMD --poolset-dir=$poolset_dir"

		if [ "$RPMEM_PM" == "APM" ]; then
			CMD="$CMD --persist-apm"
		fi

		if [ "$RPMEM_CMD" ]; then
			RPMEM_CMD="$RPMEM_CMD$SEPARATOR$CMD"
		else
			RPMEM_CMD=$CMD
		fi

		require_node_log_files $slave rpmemd$UNITTEST_NUM.log
	done
	RPMEM_CMD="\"$RPMEM_CMD\""

	RPMEM_ENABLE_SOCKETS=0
	RPMEM_ENABLE_VERBS=0

	case "$RPMEM_PROVIDER" in
	sockets)
		RPMEM_ENABLE_SOCKETS=1
		;;
	verbs)
		RPMEM_ENABLE_VERBS=1
		;;
	*)
		msg "$UNITTEST_NAME: SKIP required: RPMEM_PROVIDER is invalid or empty"
		exit 0
		;;
	esac

	export_vars_node $master RPMEM_CMD
	export_vars_node $master RPMEM_ENABLE_SOCKETS
	export_vars_node $master RPMEM_ENABLE_VERBS

	if [ -n ${UNITTEST_DO_NOT_CHECK_OPEN_FILES+x} ]; then
		export_vars_node $master UNITTEST_DO_NOT_CHECK_OPEN_FILES
	fi
	if [ -n ${PMEMOBJ_NLANES+x} ]; then
		export_vars_node $master PMEMOBJ_NLANES
	fi
	if [ -n ${RPMEM_MAX_NLANES+x} ]; then
		export_vars_node $master RPMEM_MAX_NLANES
	fi

	require_node_log_files $master rpmem$UNITTEST_NUM.log
	require_node_log_files $master $PMEMOBJ_LOG_FILE
}

#
# init_valgrind_on_node -- prepare valgrind on nodes
#    usage: init_valgrind_on_node <node list>
#
function init_valgrind_on_node() {
	# When librpmem is preloaded libfabric does not close all opened files
	# before list of opened files is checked.
	local UNITTEST_DO_NOT_CHECK_OPEN_FILES=1
	local LD_PRELOAD=../$BUILD/librpmem.so
	CHECK_NODES=""

	for node in "$@"
	do
		validate_node_number $node
		export_vars_node $node LD_PRELOAD
		export_vars_node $node UNITTEST_DO_NOT_CHECK_OPEN_FILES
		CHECK_NODES="$CHECK_NODES $node"
	done
}

#
# is_valgrind_enabled_on_node -- echo the node number if the node has
#                                initialized valgrind environment by calling
#                                init_valgrind_on_node
#    usage: is_valgrind_enabled_on_node <node>
#
function is_valgrind_enabled_on_node() {
	for node in $CHECK_NODES
	do
		if [ "$node" -eq "$1" ]; then
			echo $1
			return
		fi
	done
	return
}

#
# pack_all_libs -- put all libraries and their links to one tarball
#
function pack_all_libs() {
	local LIBS_TAR_DIR=$(pwd)/$1
	cd $DIR_SRC
	tar -cf $LIBS_TAR_DIR ./debug/*.so* ./nondebug/*.so*
	cd - > /dev/null
}

#
# copy_common_to_remote_nodes -- copy common files to all remote nodes
#
function copy_common_to_remote_nodes() {

	local NODES_ALL_MAX=$((${#NODE[@]} - 1))
	local NODES_ALL_SEQ=$(seq -s' ' 0 $NODES_ALL_MAX)

	DIR_SYNC=$1
	if [ "$DIR_SYNC" != "" ]; then
		[ ! -d $DIR_SYNC ] \
		&& fatal "error: $DIR_SYNC does not exist or is not a directory"
	fi

	# add all libraries to the 'to-copy' list
	local LIBS_TAR=libs.tar
	pack_all_libs $LIBS_TAR

	if [ "$DIR_SYNC" != "" -a "$(ls $DIR_SYNC)" != "" ]; then
		FILES_COMMON_DIR="$DIR_SYNC/* $LIBS_TAR"
	else
		FILES_COMMON_DIR="$FILES_COMMON_DIR $LIBS_TAR"
	fi

	for N in $NODES_ALL_SEQ; do
		# validate node's address
		[ "${NODE[$N]}" = "" ] \
			&& fatal "error: address of node #$N is not provided"

		check_if_node_is_reachable $N
		[ $? -ne 0 ] \
			&& msg "warning: node #$N (${NODE[$N]}) is unreachable, skipping..." \
			&& continue

		# validate the working directory
		[ "${NODE_WORKING_DIR[$N]}" = "" ] \
			&& msg ": warning: working directory for node #$N (${NODE[$N]}) is not provided, skipping..." \
			&& continue

		# create the working dir if it does not exist
		run_command ssh $SSH_OPTS ${NODE[$N]} "mkdir -p ${NODE_WORKING_DIR[$N]}"

		# copy all common files
		run_command scp $SCP_OPTS $FILES_COMMON_DIR ${NODE[$N]}:${NODE_WORKING_DIR[$N]} > /dev/null
		# unpack libraries
		run_command ssh $SSH_OPTS ${NODE[$N]} "cd ${NODE_WORKING_DIR[$N]} \
			&& tar -xf $LIBS_TAR && rm -f $LIBS_TAR"
	done

	rm -f $LIBS_TAR
}

#
# copy_test_to_remote_nodes -- copy all unit test binaries to all remote nodes
#
function copy_test_to_remote_nodes() {

	local NODES_ALL_MAX=$((${#NODE[@]} - 1))
	local NODES_ALL_SEQ=$(seq -s' ' 0 $NODES_ALL_MAX)

	for N in $NODES_ALL_SEQ; do
		# validate node's address
		[ "${NODE[$N]}" = "" ] \
			&& fatal "error: address of node #$N is not provided"

		check_if_node_is_reachable $N
		[ $? -ne 0 ] \
			&& msg "warning: node #$N (${NODE[$N]}) is unreachable, skipping..." \
			&& continue

		# validate the working directory
		[ "${NODE_WORKING_DIR[$N]}" = "" ] \
			&& msg ": warning: working directory for node #$N (${NODE[$N]}) is not provided, skipping..." \
			&& continue

		local DIR=${NODE_WORKING_DIR[$N]}/$curtestdir

		# create a new test dir
		run_command ssh $SSH_OPTS ${NODE[$N]} "rm -rf $DIR && mkdir -p $DIR"

		# create the working data dir
		run_command ssh $SSH_OPTS ${NODE[$N]} "mkdir -p \
			${DIR}/data"

		# copy all required files
		[ $# -gt 0 ] && run_command scp $SCP_OPTS $* ${NODE[$N]}:$DIR > /dev/null
	done

	return 0
}

#
# enable_log_append -- turn on appending to the log files rather than truncating them
# It also removes all log files created by tests: out*.log, err*.log and trace*.log
#
function enable_log_append() {
	rm -f $OUT_LOG_FILE
	rm -f $ERR_LOG_FILE
	rm -f $TRACE_LOG_FILE
	export UNITTEST_LOG_APPEND=1
}

# clean data directory on all remote
# nodes if remote test failed
if [ "$CLEAN_FAILED_REMOTE" == "y" ]; then
	NODES_ALL=$((${#NODE[@]} - 1))
	MYPID=$$

	for ((i=0;i<=$NODES_ALL;i++));
	do

		if [[ -z "${NODE_WORKING_DIR[$i]}" || -z "$curtestdir" ]]; then
			echo "Invalid path to tests data: ${NODE_WORKING_DIR[$i]}/$curtestdir/data/"
			exit 1
		fi

		N[$i]=${NODE_WORKING_DIR[$i]}/$curtestdir/data/
		run_command ssh $SSH_OPTS ${NODE[$i]} "rm -rf ${N[$i]}; mkdir ${N[$i]}"

		if [ $? -eq 0 ]; then
			verbose_msg "Removed data from: ${NODE[$i]}:${N[$i]}"
		fi
	done
	exit 0
fi

# calculate the minimum of two or more numbers
minimum() {
	local min=$1
	shift
	for val in $*; do
		if [[ "$val" < "$min" ]]; then
			min=$val
		fi
	done
	echo $min
}
