#!/usr/bin/env perl
# PDL interop: shared pool as backing store for PDL computation
#
# Patterns shown:
#   1. Pool → PDL: bulk-read via slot_sv → set_dataref (zero-copy-ish)
#   2. PDL → Pool: compute, write back via typed set() or raw bytes
#   3. Cross-process: parent fills pool, child creates PDL and computes
#
# Requires: PDL

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../blib/lib", "$FindBin::Bin/../blib/arch";

eval { require PDL; PDL->import; 1 }
    or die "PDL required: install with cpanm PDL\n";

use POSIX qw(_exit);
use Data::Pool::Shared;

my $N = shift || 1000;

# F64 pool — each slot is one double
my $pool = Data::Pool::Shared::F64->new(undef, $N);
printf "pool: %d F64 slots\n", $pool->capacity;

# fill with sample data
my @slots;
for my $i (0 .. $N - 1) {
    my $s = $pool->alloc;
    $pool->set($s, sin($i * 0.01) * 100 + rand(5));
    push @slots, $s;
}

# =====================================================
# Method 1: Pool → PDL via get_dataref / set_dataref
# =====================================================

# Read raw bytes from contiguous pool slots into a PDL piddle
# Pool data is contiguous at data_ptr when slots are 0..N-1
my $pdl = PDL->new_from_specification(PDL::double(), $N);

# Bulk copy: collect slot bytes → set_dataref
my $raw = '';
$raw .= $pool->slot_sv($_) for @slots;
${$pdl->get_dataref} = $raw;
$pdl->upd_data;

my @st = $pdl->stats;
printf "\n[pool→pdl] min=%.2f max=%.2f mean=%.2f rms=%.2f\n",
    $st[3], $st[4], $st[0], $st[6];

# =====================================================
# Method 2: PDL → Pool — compute, write results back
# =====================================================

# Normalize to 0..1 range
my $min = $pdl->min;
my $max = $pdl->max;
my $normalized = ($pdl - $min) / ($max - $min);

# Write back via typed set() — PDL::list extracts native doubles
my @norm_vals = $normalized->list;
$pool->set($slots[$_], $norm_vals[$_]) for 0 .. $#slots;

printf "[pdl→pool] normalized: slot[0]=%.4f slot[-1]=%.4f mean=%.4f\n",
    $pool->get($slots[0]), $pool->get($slots[-1]), $normalized->avg;

# =====================================================
# Method 3: PDL → Pool via raw bytes (set_dataref → pool)
# =====================================================

# Compute a result PDL
my $squared = $normalized ** 2;

# Extract raw bytes from PDL via get_dataref
my $sq_bytes = ${$squared->get_dataref};

# Write raw 8-byte chunks back to F64 slots
# (For F64, 8 raw bytes = one double = one slot)
for my $i (0 .. $#slots) {
    my $val = unpack('d<', substr($sq_bytes, $i * 8, 8));
    $pool->set($slots[$i], $val);
}

printf "[raw→pool] squared: slot[0]=%.6f slot[-1]=%.6f\n",
    $pool->get($slots[0]), $pool->get($slots[-1]);

# =====================================================
# Method 4: Round-trip verification via set_dataref
# =====================================================

# Read pool → PDL → verify
my $verify_pdl = PDL->new_from_specification(PDL::double(), $N);
my $verify_raw = '';
$verify_raw .= $pool->slot_sv($_) for @slots;
${$verify_pdl->get_dataref} = $verify_raw;
$verify_pdl->upd_data;

printf "[roundtrip] min=%.6f max=%.6f (expect ~0 and ~1)\n",
    $verify_pdl->min, $verify_pdl->max;

# =====================================================
# Method 5: Cross-process — parent fills, child computes
# =====================================================

# Reset pool to original data for child
$pool->set($slots[$_], sin($_ * 0.01) * 100 + 2.5) for 0 .. $#slots;

my $pid = fork // die "fork: $!";
if ($pid == 0) {
    # child: bulk-read pool → PDL, compute stats
    my $child_pdl = PDL->new_from_specification(PDL::double(), $N);
    my $child_raw = '';
    $child_raw .= $pool->slot_sv($_) for @slots;
    ${$child_pdl->get_dataref} = $child_raw;
    $child_pdl->upd_data;

    my @cst = $child_pdl->stats;
    printf "[child]    mean=%.2f median=%.2f (from %d pool slots)\n",
        $cst[0], $cst[2], $N;

    # child writes smoothed data back to pool
    my $smoothed = $child_pdl->conv1d(ones(10) / 10);
    my @sm = $smoothed->list;
    # conv1d output has same length but border effects
    $pool->set($slots[$_], $sm[$_]) for 0 .. $#sm;

    _exit(0);
}
waitpid($pid, 0);

# parent reads child's smoothed results
printf "[parent]   slot[50] after child smoothing: %.2f\n",
    $pool->get($slots[50]);
printf "[parent]   data_ptr=0x%x (for C/FFI/XS interop)\n",
    $pool->data_ptr;

$pool->free($_) for @slots;
printf "\ndone: pool used=%d\n", $pool->used;
