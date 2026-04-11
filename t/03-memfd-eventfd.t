use strict;
use warnings;
use Test::More;
use POSIX qw(_exit);
use Data::Pool::Shared;

# --- memfd ---

my $pool = Data::Pool::Shared::I64->new_memfd("test_pool", 20);
ok $pool, 'created memfd pool';
ok !defined $pool->path, 'memfd has no path';
my $memfd = $pool->memfd;
ok $memfd >= 0, 'memfd returns valid fd';

my $idx = $pool->alloc;
$pool->set($idx, 42);

# new_from_fd
my $pool2 = Data::Pool::Shared::I64->new_from_fd($memfd);
ok $pool2, 'opened pool from fd';
is $pool2->get($idx), 42, 'data visible via fd-opened handle';
is $pool2->capacity, 20, 'capacity matches';

# alloc from second handle
my $idx2 = $pool2->alloc;
ok defined $idx2, 'alloc via fd-opened handle';
$pool2->set($idx2, 99);
is $pool->get($idx2), 99, 'data visible in original handle';

$pool->free($idx);
$pool2->free($idx2);

# memfd across fork
$idx = $pool->alloc;
$pool->set($idx, 777);

my $pid = fork;
die "fork: $!" unless defined $pid;
if ($pid == 0) {
    my $child = Data::Pool::Shared::I64->new_from_fd($memfd);
    _exit($child->get($idx) == 777 ? 0 : 1);
}
waitpid($pid, 0);
is $? >> 8, 0, 'memfd fd inherited across fork';
$pool->free($idx);

# --- memfd with Str variant ---

my $spool = Data::Pool::Shared::Str->new_memfd("str_pool", 10, 32);
ok $spool, 'Str memfd pool';
my $sfd = $spool->memfd;
my $si = $spool->alloc;
$spool->set($si, "memfd string");
my $spool2 = Data::Pool::Shared::Str->new_from_fd($sfd);
is $spool2->get($si), "memfd string", 'Str data via fd';
$spool->free($si);

# --- eventfd ---

my $epool = Data::Pool::Shared::I64->new_memfd("efd_pool", 10);
is $epool->fileno, -1, 'no eventfd initially';

my $efd = $epool->eventfd;
ok $efd >= 0, 'eventfd created';
is $epool->fileno, $efd, 'fileno returns eventfd';

ok $epool->notify, 'notify succeeds';
ok $epool->notify, 'notify again';
my $count = $epool->eventfd_consume;
is $count, 2, 'eventfd_consume returns accumulated count';

# consume when empty returns undef
my $empty = $epool->eventfd_consume;
ok !defined $empty, 'eventfd_consume returns undef when empty';

# eventfd_set with external fd
my $efd2 = $epool->eventfd;
ok $efd2 >= 0, 'new eventfd created (replaces old)';
is $epool->fileno, $efd2, 'fileno updated';

# --- eventfd across fork ---

$epool->notify;
$pid = fork;
die "fork: $!" unless defined $pid;
if ($pid == 0) {
    # child inherits eventfd
    $epool->notify;
    _exit(0);
}
waitpid($pid, 0);
$count = $epool->eventfd_consume;
is $count, 2, 'eventfd accumulates across fork';

# --- unlink (class method form) ---

use File::Temp qw(tmpnam);
my $upath = tmpnam() . '.shm';
my $upool = Data::Pool::Shared::I64->new($upath, 5);
ok -f $upath, 'file exists';

# instance unlink
$upool->unlink;
ok !-f $upath, 'file removed by instance unlink';

# class method unlink
$upool = Data::Pool::Shared::I64->new($upath, 5);
ok -f $upath, 'file recreated';
Data::Pool::Shared->unlink($upath);
ok !-f $upath, 'file removed by class unlink';

# unlink on anonymous croaks
eval { $epool->unlink };
like $@, qr/cannot unlink/, 'unlink on memfd croaks';

# --- sync ---

my $spath = tmpnam() . '.shm';
END { unlink $spath if $spath && -f $spath }
my $sxpool = Data::Pool::Shared::I64->new($spath, 5);
my $sxi = $sxpool->alloc;
$sxpool->set($sxi, 42);
eval { $sxpool->sync };
ok !$@, 'sync does not croak';
$sxpool->free($sxi);

done_testing;
