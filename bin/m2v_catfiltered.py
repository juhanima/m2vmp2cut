#!/usr/bin/env python
# -*- coding: utf-8 -*-
#
# Author: Tomi Ollila -- too ät iki piste fi
#
#       Copyright (c) 2004 Tomi Ollila
#           All rights reserved
#
# Created: Sun Sep 19 08:07:37 EEST 2004 too
# Last modified: Wed 06 May 2015 22:42:46 +0300 too
#
# This program is released under GNU GPL. Check
# http://www.fsf.org/licenses/licenses.html
# to get your own copy of the GPL license.

from __future__ import print_function

import sys, os
import struct

class m2vbuf:
    SIZE = 65536

    def __init__(self, filename):
        self.file = open(filename, 'rb')
        self.buf = ''
        self.offset = 0
        #self.pos = 0
        self.len = 0
        self.gone = 0

        while True:
            self.fillbuf(self.len - 0)
            try:
                self.pos = self.buf.index(b'\000\000\001', 0, self.len)
                return
            except ValueError:
                pass

    def fillbuf(self, rest):
        if rest > 0:
            nr = self.SIZE - rest
            if nr == 0:
                raise ValueError
            self.buf = self.buf[self.offset:] + self.file.read(nr)
            self.gone += self.offset
        else:
            self.gone += self.len
            self.buf = self.file.read(self.SIZE)

        self.len = len(self.buf)
        self.offset = 0

        if self.len == rest:
            self.offset = self.len
            raise EOFError

    def filepos(self):
        return self.gone + self.offset

    def next(self):
        self.offset = self.pos
        while True:
            try:
                self.pos = self.buf.index(b'\000\000\001', \
                                          self.offset + 3, self.len)
                return self.buf[self.offset:self.pos]
            except ValueError:
                pass

            try:
                self.fillbuf(self.len - self.offset)
            except EOFError:
                if self.len == self.offset:
                    raise EOFError
                return self.buf[self.offset:]

class G:
    intra = 0
    nonintra = 0
    dispext_hdr = 0
    frames = 0
    fcount = 0

def f_picture(G, buf):    G.fcount += 1; return True
def f_user_data(G, buf):  return True
def f_seq_error(G, buf):  return True
def f_seq_end(G, buf):    return False
def f_gop(G, buf):        return True

def f_seq_header(G, buf):

    byteout.write(buf[0:11])

    lastinfo = buf[11]
    if type(lastinfo) is not int: lastinfo = ord(lastinfo) # python2 compatibil
    load_intra_quantiser_matrix = lastinfo & 0x02

    if load_intra_quantiser_matrix:

        nilastinfo = buf[75]
        if type(nilastinfo) is not int: nilastinfo = ord(nilastinfo)
        load_non_intra_quantiser_matrix = nilastinfo & 0x01

        if G.intra == 0:
            if G.nonintra == 0 or load_non_intra_quantiser_matrix == 0:
                byteout.write(xchr(lastinfo & 0xfc))
                return False

            # G.nonintra = 1 and load_non_intra_quantiser_matrix = 1
            byteout.write(xchr((lastinfo & 0xfd) | 0x01))
            byteout.write(buf[76:140])
            return False

        # G.intra = 1 (and load_intra_quantiser_matrix = 1)
        if G.nonintra == 0 or load_non_intra_quantiser_matrix == 0:
            byteout.write(buf[11:75])
            byteout.write(xchr(nilastinfo & 0xfe))
            return False

        # G.nonintra = 1 and load_non_intra_quantiser_matrix = 1
        byteout.write(buf[11:140])
        return False

    # load_intra_quantiser_matrix = 0
    load_non_intra_quantiser_matrix = lastinfo & 0x01

    if G.nonintra and load_non_intra_quantiser_matrix:
        byteout.write(buf[11:76])
        return False

    # G.nonintra = 0 or load_non_intra_quantiser_matrix = 0
    byteout.write(xchr(lastinfo & 0xfc))

    return False


def f_ext_start(G, buf):
    if G.dispext_hdr:
        return True

    ext_id = ord(buf[4]) & 0xf0
    #print >> sys.stderr, ext_id
    if ext_id == 0x20:
        return False

    return True


scode_actions = {
    0x00: f_picture,
    0xb2: f_user_data,
    0xb3: f_seq_header,
    0xb4: f_seq_error,
    0xb5: f_ext_start,
    0xb7: f_seq_end,
    0xb8: f_gop
    }


if len(sys.argv) < 6:
    sys.exit(1)

G.intra = int(sys.argv[1])
G.nonintra = int(sys.argv[2])
G.dispext_hdr = int(sys.argv[3])
G.frames = int(sys.argv[4])

if hasattr(sys.stdout, 'buffer'):
    byteout = sys.stdout.buffer  # python3
    xchr = lambda x: x.to_bytes(1, byteorder=sys.byteorder, signed=False)
else:
    byteout = sys.stdout  # python2
    xchr = chr
    pass

f = m2vbuf(sys.argv[5])

while True:
    try:
        buf = f.next()
    except EOFError:
        if G.fcount != G.frames:
            print('NOTE: frame count %d does not match expected %d.' % \
                  (G.fcount, G.frames), file=sys.stderr)
        sys.exit(0)

    a = buf[3]
    if type(a) is not int: a = ord(a) # python 2 compatibility

    try:
        if scode_actions[a](G, buf):
            byteout.write(buf)
    except KeyError:
        if a < 0xa0:
            # slice, ignoring for now.
            byteout.write(buf)
        else:
            print("File contains mpeg header 0x%02x." % a,
                  "Did you demultiplex your source?", sep='\n', file=sys.stderr)
            sys.exit(1)
