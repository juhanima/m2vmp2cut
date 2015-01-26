#!/usr/bin/perl
# cut without re-encoding anything, cutpoint restrictions apply
# -*- cperl -*-
#
# Author: Tomi Ollila -- too ät iki piste fi
#
#	Copyright (c) 2012 Tomi Ollila
#	    All rights reserved
#
# Created: Fri 26 Oct 2012 18:55:56 EEST too
# Last modified: Thu 22 Jan 2015 18:41:51 +0200 too

use 5.8.1;
use strict;
use warnings;

my $LIBPATH;
use Cwd 'abs_path';
BEGIN { $LIBPATH = abs_path($0); $LIBPATH =~ s|[^/]+/[^/]+$|bin|; }
use lib $LIBPATH;
use m2vmp2cut;

if (@ARGV > 0 and (@ARGV > 1 or ($ARGV[0] ne '4:3' and $ARGV[0] ne '16:9'))) {
    $0 =~ s|.*/||;
    die "
 Usage: $0 [4:3|16:9]

 Cut without re-encoding. Start frames needs to be I-frames
 End frames must be I or P frames. If this is not the case
 cut will not happen. Note that in current m2vcut gui tool
 selecting end frames selects the start of cutout frames
 i.e. end selection must be one-after the last included frame.

 FIXME: options for dvd/blu-ray subtitles (and also end cut
        in m2vcut gui tool!)
\n";
}

my $dir = $ENV{M2VMP2CUT_MEDIA_DIRECTORY};
my $bindir = $ENV{M2VMP2CUT_CMD_PATH};

my $videofile = "$dir/video.m2v"; needfile $videofile;
my $indexfile = "$dir/video.index"; needfile $indexfile;
my $cutpoints = "$dir/cutpoints"; needfile $cutpoints;

needfile "$dir/audio.mp2";

my @cutpoints;
getcutpoints $cutpoints, \@cutpoints;

openI $indexfile;
$" = ',';
my @cpargs;
my @asrs = (0,0,0,0,0); # we trust there is no asrs w/ value > 4
foreach (@cutpoints)
{
    my ($s, $e) = split('-');

    my ($gop, $frametypes);
    while (<I>) {
	#        offset   gop   frame  iframe-pos asr ... frametypes
	if (/^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d)\s.*\s[BDIPX_]+\s*$/) {
	    my $ifn = $3 + $4;
	    next if ($ifn < $s );
	    if ($s == $ifn) {
		my $frames = $e - $s;
		push @cpargs, "$1,$frames";
		$asrs[$5]++;
		last;
	    }
	    die "Frame #$s is not an I-frame (or $s slipped through)!\n";
	}
    }
    while (<I>) {
	#        offset   gop    frame   ...   asr  #of-frames frametypes
	if (/^\s*(\d+)\s+(\d+)\s+(\d+)\s+\d+\s+(\d).*?(\d+)\s+([BDIPX_]+)\s*$/)
	{
	    my $lfn = $3 + $5;
	    $asrs[$4]++, next if ($lfn < $e);
	    my $off = $e - $3 - 1;
	    die "Frame #$e slipped through!\n" if $off < 0;
	    my @frametypes = split '', $6;
	    my $ftype = $frametypes[$off];
	    $e = '', last if $ftype eq 'I' or $ftype eq 'P';
	    $e--;
	    die "Frame #$e is not an I-frame or P-frame (is $ftype-frame)!\n";
	}
    }
    die "Frame #$e not checked/found!\n" if $e;
}
close I;

unless (@cpargs) {
    die "
 There was either no selections made to be cut or the video index file
 was generated using older version of m2vmp2cut. If the latter is the
 case, remove '$indexfile' and then execute
 'm2vmp2cut $dir select' again.
 This will recreate new index file which is compatible with this tool.
\n";
}

# XXX add printing of asr counts...
my $asr = (@ARGV == 1? ($ARGV[0] eq '4:3'? 2: 3): ($asrs[2] > $asrs[3]? 2: 3));

# XXX work in progress...
my $subtitlefile = "$dir/subtitle.sup";
if (-f "$dir/sp1-1.suptime") {
    system "$bindir/supcut.pl", $dir;
    die "exit code $?\n" if $?;
    system "$bindir/pgssupout", qw/720 576/, "$dir/sp1-1.supcut",
#      "$dir/in_sp/in_st%05dp$ps.bmp", $subtitlefile;
      "$dir/in1/st1-1-%05d.bmp", $subtitlefile;
    die "exit code $?\n" if $?;
}

if (-s $subtitlefile)
{
    # unfortunately mkvmerge cannot take input from fifos, so in this case
    # just write temporary video and audio files that are to be deleted
    # at the end...

    eval "END { unlink '$dir/tmp.mp2', '$dir/tmp.m2v' }";

    unless (xfork) {
	warn "Executing getmp2.sh $dir ...\n";
	open STDOUT, '>', "$dir/tmp.mp2" or die $!;
	system  "$bindir/getmp2.sh", $dir;
	exit $? if $?;
	warn "Executing m2vstream $asr $videofile @cpargs ...\n";
	open STDOUT, '>', "$dir/tmp.m2v" or die $!;
	exec "$bindir/m2vstream", $asr, $videofile, @cpargs;
    }
    while (1) {
	last if wait < 0;
	die "exit code $?\n" if $?;
    }
    system qw/mkvmerge -o out.mkv/, "$dir/tmp.m2v", "$dir/tmp.mp2", $subtitlefile;
    exit;
}
# else

my $RUNTIME_DIR = $ENV{XDG_RUNTIME_DIR} || 0;
unless ($RUNTIME_DIR and -d $RUNTIME_DIR
	and -x $RUNTIME_DIR and $RUNTIME_DIR !~ /\s/) {
    $RUNTIME_DIR = "/tmp/runtime-$<";
    mkdir $RUNTIME_DIR; # ignore if fail.
    chmod 0700, $RUNTIME_DIR or die "Cannot chown '$RUNTIME_DIR': $!\n";
}

my ($videofifo, $audiofifo) = ( "$RUNTIME_DIR/icut-fifo.video.$$",
				"$RUNTIME_DIR/icut-fifo.audio.$$" );

eval 'END { unlink $videofifo, $audiofifo }';

system 'mkfifo', $videofifo;
system 'mkfifo', $audiofifo;

unless (xfork) {
    open STDOUT, '>', $audiofifo or die $!;
    exec "$bindir/getmp2.sh", $dir;
}

unless (xfork) {
    warn "Executing m2vstream $asr $videofile @cpargs\n";
    open STDOUT, '>', $videofifo or die $!;
    exec "$bindir/m2vstream", $asr, $videofile, @cpargs;
}

system qw/mplex -f 8 -o out.mpg/, $videofifo, $audiofifo;
