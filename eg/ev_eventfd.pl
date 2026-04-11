#!/usr/bin/env perl
# EV event loop integration via eventfd
# Pool changes trigger an EV::io watcher — useful for reactive patterns

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../blib/lib", "$FindBin::Bin/../blib/arch";

eval { require EV } or die "EV module required: install with cpanm EV\n";

use Data::Pool::Shared;

my $pool = Data::Pool::Shared::I64->new(undef, 8);
my $efd = $pool->eventfd;
printf "pool capacity=%d, eventfd=%d\n\n", $pool->capacity, $efd;

# watcher: fires when something calls notify()
my $watcher = EV::io $efd, EV::READ, sub {
    my $n = $pool->eventfd_consume;
    printf "[watcher] %d notifications, pool used=%d/%d\n",
        $n // 0, $pool->used, $pool->capacity;
};

# periodic allocator: alloc a slot every 0.3s, notify
my $alloc_count = 0;
my $alloc_timer = EV::timer 0.1, 0.3, sub {
    my $s = $pool->try_alloc;
    if (defined $s) {
        $alloc_count++;
        $pool->set($s, $alloc_count * 100);
        printf "[alloc]   slot %d = %d\n", $s, $pool->get($s);
        $pool->notify;
    } else {
        printf "[alloc]   pool full, skipping\n";
    }
};

# periodic freer: free oldest slot every 0.5s, notify
my $free_timer = EV::timer 1.0, 0.5, sub {
    my $slots = $pool->allocated_slots;
    if (@$slots) {
        my $s = $slots->[0];
        printf "[free]    slot %d (was %d)\n", $s, $pool->get($s);
        $pool->free($s);
        $pool->notify;
    }
};

# stop after 5 seconds
EV::timer 5, 0, sub {
    printf "\n[done]    stopping after 5s\n";
    EV::break;
};

EV::run;
printf "final: used=%d\n", $pool->used;
$pool->reset;
