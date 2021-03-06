#
# Copyright 2019, Intel Corporation
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
#
# libpmempool_bttdev/TEST4 -- test for checking btt
#

. ..\unittest\unittest.ps1

require_test_type medium
require_fs_type any
#
# For a large pool, util_map consumes so much memory.
#
require_free_physical_memory 3G
#
# Automatic page file size management eliminate the risk
# of exceeding the available resources.
#
require_automatic_managed_pagefile

setup

$POOL="$DIR\file.pool"
$LOG="out${Env:UNITTEST_NUM}.log"
$LOG_TEMP="out${Env:UNITTEST_NUM}_part.log"
rm $LOG -Force -ea si
rm $LOG_TEMP -Force -ea si
touch $LOG_TEMP
$EXE="$Env:EXE_DIR\libpmempool_test$Env:EXESUFFIX"

truncate -s 1T $POOL
expect_normal_exit $BTTCREATE -s 1T -b 512M -t $POOL >> $LOG

expect_normal_exit $PMEMSPOIL $POOL "bttdevice.arena(0).btt_info.sig=ERROR" `
	"bttdevice.arena(0).btt_info_backup.sig=ERROR" `
	"bttdevice.arena(1).btt_info.sig=ERROR"

expect_normal_exit $EXE -r 1 -t btt $POOL >> $LOG_TEMP

cat -Encoding Ascii $LOG | out-file -append -Encoding Ascii -literalpath $LOG_TEMP

mv -Force $LOG_TEMP $LOG

check_file $POOL

check

pass
