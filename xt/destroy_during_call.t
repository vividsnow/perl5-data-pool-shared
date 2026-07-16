use strict;
use warnings;
use Test::More;
use Config;
use Data::Pool::Shared;

plan skip_all => 'fork required' unless $Config{d_fork};

# Argument magic (overload) that explicitly DESTROYs the pool object whose
# C handle the method is about to use.  Before the REEXTRACT fix the method
# went on to dereference the freed handle (SEGV); after it the method must
# croak cleanly.  The child exits 0 when the method croaked, 7 when it ran
# on through the freed memory.

{
    package Evil;
    use overload
        '""' => sub { $_[0][0]->DESTROY; 'k' },
        '0+' => sub { $_[0][0]->DESTROY; 0 },
        fallback => 1;
}

my @cases = (
    [ alloc   => sub { my ($p, $e) = @_; $p->alloc($e) } ],       # timeout arg, SvNV
    [ alloc_n => sub { my ($p, $e) = @_; $p->alloc_n(2, $e) } ],  # timeout arg, SvNV
    [ free_n  => sub { my ($p, $e) = @_; $p->free_n([$e]) } ],    # array element, SvUV
);

for my $case (@cases) {
    my ($method, $call) = @$case;
    my $pid = fork();
    unless ($pid) {
        my $pool = Data::Pool::Shared->new(undef, 10, 32);  # anonymous pool
        my $evil = bless [$pool], 'Evil';
        my $ok = eval { $call->($pool, $evil); 1 };
        exit($ok ? 7 : 0);  # 0 = croaked (correct), 7 = ran on through freed memory
    }
    waitpid($pid, 0);
    my $st = $?;
    ok !($st & 127), "$method: no crash when argument magic destroys the handle"
        or diag sprintf('died with signal %d', $st & 127);
    is $st >> 8, 0, "$method: croaks instead of using the freed handle";
}

done_testing;
