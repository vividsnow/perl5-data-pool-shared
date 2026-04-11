#!/usr/bin/env perl
# OpenGL particle system backed by shared pool
#
# Pattern: Pool stores particle state (x, y, vx, vy per particle as 4 F64s),
# worker process updates physics, renderer reads via data_ptr/ptr for VBO upload.
#
# This is a structural example — actual rendering requires OpenGL::Modern + GLFW/SDL.
# The data flow pattern is what matters: shared memory → GPU upload via raw pointer.
#
# Requires: OpenGL::Modern (optional, shows the pattern without it)

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../blib/lib", "$FindBin::Bin/../blib/arch";
use POSIX qw(_exit);
use Time::HiRes qw(time sleep);
use Data::Pool::Shared;

my $N = shift || 100;  # number of particles

# Each particle: 4 doubles (x, y, vx, vy) = 32 bytes per slot
my $pool = Data::Pool::Shared->new(undef, $N, 32);
printf "particle pool: %d particles, %d bytes each, data_ptr=0x%x\n",
    $N, $pool->elem_size, $pool->data_ptr;

# Initialize particles
my @particles;
for my $i (0 .. $N - 1) {
    my $s = $pool->alloc;
    push @particles, $s;
    # pack x, y, vx, vy as 4 little-endian doubles
    my $data = pack('d<4',
        rand(800),              # x
        rand(600),              # y
        (rand(2) - 1) * 50,    # vx
        (rand(2) - 1) * 50,    # vy
    );
    $pool->set($s, $data);
}

# Physics worker: update positions in a loop
my $pid = fork // die "fork: $!";
if ($pid == 0) {
    my $dt = 0.016;  # ~60fps timestep
    for (1 .. 100) {
        for my $s (@particles) {
            my ($x, $y, $vx, $vy) = unpack('d<4', $pool->get($s));
            $x += $vx * $dt;
            $y += $vy * $dt;
            # bounce off walls
            if ($x < 0 || $x > 800) { $vx = -$vx; $x += $vx * $dt * 2 }
            if ($y < 0 || $y > 600) { $vy = -$vy; $y += $vy * $dt * 2 }
            $pool->set($s, pack('d<4', $x, $y, $vx, $vy));
        }
        sleep($dt);
    }
    _exit(0);
}

# Renderer side: read particle positions for display/upload
# In real code, this would be:
#   glBindBuffer(GL_ARRAY_BUFFER, $vbo);
#   glBufferData_c(GL_ARRAY_BUFFER, $N * 32, $pool->data_ptr, GL_STREAM_DRAW);
# Or per-slot:
#   glBufferSubData_c(GL_ARRAY_BUFFER, $i * 32, 32, $pool->ptr($particles[$i]));

for (1 .. 5) {
    sleep(0.3);
    # sample a few particles
    for my $i (0, $N/2, $N-1) {
        my $s = $particles[$i];
        my ($x, $y, $vx, $vy) = unpack('d<4', $pool->get($s));
        printf "  particle[%3d] pos=(%.1f, %.1f) vel=(%.1f, %.1f)\n",
            $i, $x, $y, $vx, $vy;
    }
    printf "  --- frame (ptr=0x%x, %d particles active) ---\n",
        $pool->data_ptr, $pool->used;
}

waitpid($pid, 0);

# final state
printf "\nfinal positions:\n";
for my $i (0, $N/2, $N-1) {
    my ($x, $y) = unpack('d<2', $pool->get($particles[$i]));
    printf "  particle[%3d] (%.1f, %.1f)\n", $i, $x, $y;
}

$pool->free($_) for @particles;
