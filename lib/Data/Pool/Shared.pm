package Data::Pool::Shared;
use strict;
use warnings;
our $VERSION = '0.01';

require XSLoader;
XSLoader::load('Data::Pool::Shared', $VERSION);

# Variant @ISA — inherit alloc/free/is_allocated/capacity/etc. from base

@Data::Pool::Shared::I64::ISA = ('Data::Pool::Shared');
@Data::Pool::Shared::F64::ISA = ('Data::Pool::Shared');
@Data::Pool::Shared::I32::ISA = ('Data::Pool::Shared');
@Data::Pool::Shared::Str::ISA = ('Data::Pool::Shared');

# Guard — auto-free on scope exit

package Data::Pool::Shared::Guard {
    sub DESTROY {
        my $self = shift;
        eval { $self->[0]->free($self->[1]) } if $self->[0];
    }
}

sub alloc_guard {
    my ($self, $timeout) = @_;
    my $idx = $self->alloc($timeout // -1);
    return unless defined $idx;
    my $guard = bless [$self, $idx], 'Data::Pool::Shared::Guard';
    return wantarray ? ($idx, $guard) : $guard;
}

sub try_alloc_guard {
    my ($self) = @_;
    my $idx = $self->try_alloc;
    return unless defined $idx;
    my $guard = bless [$self, $idx], 'Data::Pool::Shared::Guard';
    return wantarray ? ($idx, $guard) : $guard;
}

# Convenience — alloc + set in one call

sub alloc_set {
    my ($self, $val, $timeout) = @_;
    my $idx = $self->alloc($timeout // -1);
    return unless defined $idx;
    $self->set($idx, $val);
    return $idx;
}

sub try_alloc_set {
    my ($self, $val) = @_;
    my $idx = $self->try_alloc;
    return unless defined $idx;
    $self->set($idx, $val);
    return $idx;
}

# Iterate allocated slots

sub each_allocated {
    my ($self, $cb) = @_;
    my $cap = $self->capacity;
    for my $i (0 .. $cap - 1) {
        $cb->($i) if $self->is_allocated($i);
    }
}

1;

__END__

=encoding utf-8

=head1 NAME

Data::Pool::Shared - Fixed-size shared-memory object pool for Linux

=head1 SYNOPSIS

    use Data::Pool::Shared;

    # Raw byte pool — 100 slots of 64 bytes each
    my $pool = Data::Pool::Shared->new('/tmp/pool.shm', 100, 64);
    my $idx = $pool->alloc;           # allocate a slot
    $pool->set($idx, "hello world");  # write data
    my $data = $pool->get($idx);      # read data
    $pool->free($idx);                # release slot

    # Typed pools
    my $ints = Data::Pool::Shared::I64->new('/tmp/ints.shm', 1000);
    my $i = $ints->alloc;
    $ints->set($i, 42);
    $ints->add($i, 8);            # atomic add, returns 50
    $ints->cas($i, 50, 99);       # atomic CAS
    say $ints->get($i);           # 99

    my $floats = Data::Pool::Shared::F64->new('/tmp/f.shm', 100);
    my $strs = Data::Pool::Shared::Str->new('/tmp/s.shm', 100, 256);

    # Guard — auto-free on scope exit
    {
        my ($idx, $guard) = $pool->alloc_guard;
        $pool->set($idx, $data);
        # ... use slot ...
    }  # auto-freed

    # Convenience
    my $idx = $ints->alloc_set(42);       # alloc + set
    my $idx = $ints->try_alloc_set(42);   # non-blocking

    # Cross-process via fork
    if (fork == 0) {
        my $child = Data::Pool::Shared::I64->new('/tmp/ints.shm', 1000);
        my $i = $child->alloc;
        $child->set($i, $$);
        exit;
    }

    # Anonymous (fork-inherited)
    my $pool = Data::Pool::Shared::I64->new(undef, 100);

    # memfd (fd-passable)
    my $pool = Data::Pool::Shared::I64->new_memfd("my_pool", 100);
    my $fd = $pool->memfd;

=head1 DESCRIPTION

Data::Pool::Shared provides a fixed-size object pool in shared memory.
Slots are allocated and freed explicitly, like a memory allocator but
for cross-process shared objects.

Unlike L<Data::Buffer::Shared> (index-based array access), Pool provides
allocate/free semantics: you request a slot, use it, and return it.
The pool tracks which slots are in use via a lock-free bitmap.

B<Linux-only>. Requires 64-bit Perl.

=head2 Variants

=over

=item L<Data::Pool::Shared> - raw byte slots (any elem_size)

=item L<Data::Pool::Shared::I64> - int64_t (atomic get/set/cas/add)

=item L<Data::Pool::Shared::F64> - double

=item L<Data::Pool::Shared::I32> - int32_t (atomic get/set/cas/add)

=item L<Data::Pool::Shared::Str> - fixed-length strings

=back

=head2 Allocation

Allocation uses a CAS-based bitmap scan (lock-free). Each 64-slot group
is managed by one atomic uint64_t word. On contention, CAS retries
automatically. When the pool is full, C<alloc> blocks on a futex until
a slot is freed.

=head2 Crash Safety

Each slot records the PID of its allocator. C<recover_stale> scans for
slots owned by dead processes and frees them. Call periodically or on
startup for crash recovery.

=head1 CONSTRUCTORS

    # Raw pool
    my $p = Data::Pool::Shared->new($path, $capacity, $elem_size);
    my $p = Data::Pool::Shared->new(undef, $capacity, $elem_size);  # anonymous
    my $p = Data::Pool::Shared->new_memfd($name, $capacity, $elem_size);
    my $p = Data::Pool::Shared->new_from_fd($fd);

    # I64 pool
    my $p = Data::Pool::Shared::I64->new($path, $capacity);
    my $p = Data::Pool::Shared::I64->new_memfd($name, $capacity);

    # Str pool
    my $p = Data::Pool::Shared::Str->new($path, $capacity, $max_len);

=head1 METHODS

=head2 Allocation

    my $idx = $pool->alloc;             # block until available
    my $idx = $pool->alloc($timeout);   # with timeout (seconds)
    my $idx = $pool->alloc(0);          # non-blocking
    my $idx = $pool->try_alloc;         # non-blocking (alias)

Returns slot index on success, C<undef> on failure/timeout.

    $pool->free($idx);                  # release slot (returns true/false)

=head2 Data Access

    my $val = $pool->get($idx);         # read slot
    $pool->set($idx, $val);             # write slot

For I64/I32 variants:

    my $ok  = $pool->cas($idx, $old, $new);  # atomic compare-and-swap
    my $val = $pool->add($idx, $delta);      # atomic add, returns new value
    my $val = $pool->incr($idx);             # atomic increment
    my $val = $pool->decr($idx);             # atomic decrement

For Str variant:

    my $max = $pool->max_len;           # maximum string length

=head2 Status

    my $ok  = $pool->is_allocated($idx);
    my $cap = $pool->capacity;
    my $esz = $pool->elem_size;
    my $n   = $pool->used;              # allocated count
    my $n   = $pool->available;         # free count
    my $pid = $pool->owner($idx);       # PID of allocator

=head2 Recovery

    my $n = $pool->recover_stale;       # free slots owned by dead PIDs
    $pool->reset;                       # free all slots (exclusive access only)

=head2 Guards

    my ($idx, $guard) = $pool->alloc_guard;           # auto-free on scope exit
    my ($idx, $guard) = $pool->alloc_guard($timeout);
    my ($idx, $guard) = $pool->try_alloc_guard;       # non-blocking

=head2 Convenience

    my $idx = $pool->alloc_set($val);           # alloc + set
    my $idx = $pool->alloc_set($val, $timeout); # with timeout
    my $idx = $pool->try_alloc_set($val);       # non-blocking

    $pool->each_allocated(sub { my $idx = shift; ... });

=head2 Common Methods

    my $p  = $pool->path;        # backing file (undef if anon)
    my $fd = $pool->memfd;       # memfd fd (-1 if not memfd)
    $pool->sync;                 # msync to disk
    $pool->unlink;               # remove backing file
    my $s  = $pool->stats;       # diagnostic hashref

=head3 eventfd Integration

    my $fd = $pool->eventfd;           # create eventfd
    $pool->eventfd_set($fd);           # use existing fd
    my $fd = $pool->fileno;            # current eventfd (-1 if none)
    $pool->notify;                     # signal eventfd
    my $n  = $pool->eventfd_consume;   # drain counter

=head1 AUTHOR

vividsnow

=head1 LICENSE

This is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
