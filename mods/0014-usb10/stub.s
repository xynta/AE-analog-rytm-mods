        | Mod 0014 - USB10: Main L/R and the 8 voice outputs in one Overbridge pass at 16 bit
        | (xynta, 2026-11-22; v2 2026-11-24: the reader kept on the writer through host
        | gaps, every skipped frame counted; mod.toml says what and why).
        |
        | Four hooks, all on the USB side; the audio engine is not touched:
        |   map_gate   the IN channel map's data stage (0x400057c6): 10 bytes -> map10, anything
        |              else -> the stock code exactly as before (8 bytes accepted, the rest stalled)
        |   pack_gate  the IN packer where it starts its staging copy (0x40005a62): 10 channels ->
        |              pack10, fewer -> the stock gather and convert
        |   cfg_desc   the OVERBRIDGE configuration descriptor with IN alternate 8 (986 bytes); the
        |              mode table's pointer and length are patched to it (registry)
        |   gap_gate   the packer's gap path (0x40005932, a frame or more sent no packet): with 10
        |              channels the reader skips the audio of every such frame and the header's
        |              count shows it; fewer channels -> stock (it skips 48 frames, whatever the gap)
        |   lead_guard called by pack10 first: the writer's lead back into its window if it left it
        |
        | Stock facts this relies on (OS 1.74 MAIN OS):
        |   0x400054c6  the map handler: per slot, code 0x80..0x87 / 0xA0 / 0xA1 -> IN_IDX[slot] =
        |               CODE_TAB[code] (the codec receive word), 0xFE -> 0, 0xFF skipped (not
        |               counted), else counted with the old index; IN_COUNT = the count. It loops 8
        |               and is also called at USB start with an 8-byte map on the stack
        |               (0x400063d2), so its bound stays 8 and map10 is a separate routine.
        |   0x40005912  the packer, in the USB interrupt once a frame (the completion of the
        |               last IN dTD): d6 = frames (47..49), d7 = IN_COUNT, d1 = where the samples
        |               go (past the 6-byte header when it is on), a3 = the dTD, whose +8 already
        |               points at the packet; 0x40005c70 queues it and returns (d6, a3 kept).
        |   0x8000cf34  the codec receive ring: 224 frames of 10 words (40 bytes), read at
        |               RING_RD, written by the audio interrupt at RING_WR.
        | SET_INTERFACE on interface 0 starts the stream for any alternate 1..15 (0x40004746) and
        | stores the number nowhere it is read again, so alternate 8 needs no code.

        .equ    MAP_STOCK,      0x400057cc        | the stock length check, with d0 = data, d1 = 8
        .equ    STALL_EP0,      0x400057e8        | stall endpoint 0 (stock's answer to a bad map)
        .equ    STATUS_IN,      0x40004076        | queue the status stage (jmp'd to with 4(sp) = 0)
        .equ    IN_IDX,         0x416c7b60        | receive word per IN slot, 16 bytes (stock fills 8)
        .equ    IN_COUNT,       0x402acde8        | IN channels
        .equ    CODE_TAB,       0x4018d5d0        | code -> receive word
        .equ    HDR_ON,         0x402acde0        | the IN packets carry the 6-byte header
        .equ    PACK_CB,        0x40005caa        | the IN dTD's completion callback
        .equ    PACK_STOCK,     0x40005a68        | the packer past the displaced lea
        .equ    PACK_TAIL,      0x40005c70        | queue the dTD, count the frames, return
        .equ    STAGING,        0x8000ad04        | the stock staging buffer (8 channels' worth)
        .equ    RING,           0x8000cf34
        .equ    RING_N,         224
        .equ    RING_RD,        0x402acd80
        .equ    RING_WR,        0x402acd70
        .equ    RING_MIN,       0x40236ebc        | the smallest lead of the writer, kept by stock

        | v2: the USB audio block's words as offsets from RING_WR (0x402acd70), for short addressing
        .equ    O_FRAMES,       0x0c              | 0x402acd7c the header's running count of frames
        .equ    O_RD,           0x10              | 0x402acd80 RING_RD
        .equ    O_RESYNC,       0x58              | 0x402acdc8 the reader to be set from the writer (stream start)
        .equ    O_SERVO,        0x64              | 0x402acdd4 the rate servo's owed frames (+1 a 49, -1 a 47)
        .equ    O_HDR,          0x70              | 0x402acde0 HDR_ON
        .equ    O_COUNT,        0x78              | 0x402acde8 IN_COUNT
        .equ    O_SOFS,         0xa8              | 0x402ace18 SOFs since the packer last ran (over 16: re-set)
        .equ    GAP_STOCK,      0x40005938        | the stock gap path past the displaced load of RING_RD
        .equ    GAP_DONE,       0x4000595c        | stores this packet's frame number, then the SOF check
        | The writer copies 32-frame blocks into the ring in the audio interrupt and moves RING_WR
        | past the block it is given, so between interrupts the ring holds the last 224 frames, the
        | newest just before RING_WR and the block at RING_WR the next one overwritten. The packer
        | finds the lead RING_WR - RING_RD at 102 or 118 (the block phase) from stock's own re-set;
        | under 49 it would read past the newest frame, over 192 inside the block overwritten next.
        .equ    LEAD_T,         110               | where lead_guard puts the reader back
        .equ    LEAD_LO,        64                | under this: back to LEAD_T (frames repeated, not counted)
        .equ    LEAD_HI,        168               | over this: forward to LEAD_T (frames skipped, counted)

        .text

        | ------------------------------------------------------------------
        | The IN map's data stage: (length 4(sp), data 8(sp)).
        | ------------------------------------------------------------------
        .align  2
map_gate:
        move.l  8(%sp),%d0                        | displaced: the data
        moveq   #8,%d1                            | displaced
        cmp.l   4(%sp),%d1
        beq.s   0f                                | 8 bytes: stock
        moveq   #10,%d1
        cmp.l   4(%sp),%d1
        beq.s   1f
        moveq   #8,%d1                            | any other length: stock (it stalls)
0:      jmp     MAP_STOCK
1:      move.l  %d0,-(%sp)
        bsr.s   map10
        addq.l  #4,%sp
        tst.l   %d0
        beq.s   2f
        clr.l   4(%sp)                            | as stock on success
        jmp     STATUS_IN
2:      jmp     STALL_EP0

        | map10(data): ten codes, each one a source, or nothing changes. -> d0 = 1 taken, 0 refused.
        .align  2
map10:
        move.l  4(%sp),%a0
        moveq   #9,%d1
1:      mvz.b   (%a0,%d1.l),%d0
        cmpi.b  #0xfe,%d0
        beq.s   2f
        cmpi.b  #0xa1,%d0
        bhi.s   8f
        cmpi.b  #0xa0,%d0
        bcc.s   2f                                | A0, A1: Main
        cmpi.b  #0x87,%d0
        bhi.s   8f
        cmpi.b  #0x80,%d0
        bcs.s   8f                                | 80..87: the voices
2:      subq.l  #1,%d1
        bpl.s   1b
        move.l  %a2,-(%sp)
        lea     CODE_TAB,%a1
        lea     IN_IDX,%a2
        moveq   #9,%d1
3:      mvz.b   (%a0,%d1.l),%d0
        cmpi.b  #0xfe,%d0
        bne.s   4f
        moveq   #0,%d0                            | FE: word 0, as stock
        bra.s   5f
4:      move.b  (%a1,%d0.l),%d0
5:      move.b  %d0,(%a2,%d1.l)
        subq.l  #1,%d1
        bpl.s   3b
        move.l  (%sp)+,%a2
        moveq   #10,%d0
        move.l  %d0,IN_COUNT                      | last: the packer sees a whole map
        moveq   #1,%d0
        rts
8:      moveq   #0,%d0
        rts

        | ------------------------------------------------------------------
        | The packer, where stock starts its staging copy. d7 = IN_COUNT.
        | ------------------------------------------------------------------
        .align  2
pack_gate:
        cmpi.w  #10,%d7
        beq.s   pack10
        lea     STAGING,%a0                       | displaced
        jmp     PACK_STOCK

        | Ten channels, 16 bit: frames x 20 bytes (+ the header), gathered from the ring and
        | converted in one pass. Free here: d0-d5, a0-a2 (the tail restores them); kept: d6, a3.
pack10:
        jsr     lead_guard                        | v2: the reader's lead into its window first
        move.l  %d6,%d0
        lsl.l   #2,%d0
        move.l  %d0,%d2
        lsl.l   #2,%d2
        add.l   %d2,%d0                           | 20 x frames
        tst.l   HDR_ON
        beq.s   1f
        addq.l  #6,%d0
1:      move.l  %d0,%d2                           | the dTD, as stock fills it
        swap    %d2
        clr.w   %d2
        bset    #7,%d2                            | total bytes, active
        move.l  %d2,4(%a3)
        move.l  %d0,32(%a3)
        move.l  #PACK_CB,%d2
        move.l  %d2,36(%a3)
        move.l  %d1,%a0                           | the samples
        move.l  RING_RD,%d3
        move.l  %d3,%d2
        lsl.l   #3,%d2
        move.l  %d2,%a1
        lsl.l   #2,%d2
        adda.l  %d2,%a1
        adda.l  #RING,%a1                         | the frame at RING_RD (40 bytes each)
        move.l  %d6,%d5
2:      lea     IN_IDX,%a2
        moveq   #5,%d4
3:      mvz.b   (%a2)+,%d2
        move.l  (%a1,%d2.l*4),%d2
        .short  0x02c2                            | byterev.l %d2: the top 16 bits, little endian, low half
        move.w  %d2,(%a0)+
        mvz.b   (%a2)+,%d2
        move.l  (%a1,%d2.l*4),%d2
        .short  0x02c2
        move.w  %d2,(%a0)+
        subq.l  #1,%d4
        bne.s   3b
        lea     40(%a1),%a1
        addq.l  #1,%d3
        cmpi.w  #RING_N,%d3
        bne.s   4f
        moveq   #0,%d3
        lea     RING,%a1
4:      subq.l  #1,%d5
        bne.s   2b
        move.l  %d3,RING_RD
        move.l  RING_WR,%d4                       | the writer's lead, the smallest kept (stock)
        sub.l   %d3,%d4
        bge.s   5f
        addi.l  #RING_N,%d4
5:      cmp.l   RING_MIN,%d4
        bge.s   6f
        move.l  %d4,RING_MIN
6:      jmp     PACK_TAIL

        | ------------------------------------------------------------------
        | The OVERBRIDGE configuration: stock's 414 bytes with IN alternate 8 added (432 bytes).
        | Built from the USB 2.0 descriptor layouts (9.6, the audio class' 9-byte endpoints).
        | ------------------------------------------------------------------
        .macro  intf num, alt, neps, cls, sub
        .byte   9, 4, \num, \alt, \neps, \cls, \sub, 0, 0
        .endm
        .macro  isoep addr, size
        .byte   9, 5, \addr, 5, (\size) & 0xff, (\size) >> 8, 1, 0, 0     | isochronous asynchronous, every frame
        .endm
        .macro  bulkep addr
        .byte   9, 5, \addr, 2, 64, 0, 0, 0, 0
        .endm

        .align  2
cfg_desc:
        .byte   9, 2, (cfg_end - cfg_desc) & 0xff, (cfg_end - cfg_desc) >> 8, 5, 1, 0, 0xc0, 3
        .byte   8, 11, 0, 3, 0xff, 0, 0, 0        | association: interfaces 0..2, vendor
        intf    0, 0, 0, 0xff, 0                  | audio from the Rytm
        intf    0, 1, 1, 0xff, 0
        isoep   0x83, 6
        intf    0, 2, 1, 0xff, 0
        isoep   0x83, 202
        intf    0, 3, 1, 0xff, 0
        isoep   0x83, 300
        intf    0, 4, 1, 0xff, 0
        isoep   0x83, 398
        intf    0, 5, 1, 0xff, 0
        isoep   0x83, 594
        intf    0, 6, 1, 0xff, 0
        isoep   0x83, 790
        intf    0, 7, 1, 0xff, 0
        isoep   0x83, 888
        intf    0, 8, 1, 0xff, 0                  | the new one: 10 channels x 16 bit x 49 frames
        isoep   0x83, 986
        intf    1, 0, 0, 0xff, 0                  | audio to the Rytm
        intf    1, 1, 1, 0xff, 0
        isoep   0x03, 104
        intf    1, 2, 1, 0xff, 0
        isoep   0x03, 300
        intf    1, 3, 1, 0xff, 0
        isoep   0x03, 398
        intf    1, 4, 1, 0xff, 0
        isoep   0x03, 496
        intf    1, 5, 1, 0xff, 0
        isoep   0x03, 692
        intf    1, 6, 1, 0xff, 0
        isoep   0x03, 888
        intf    1, 7, 1, 0xff, 0
        isoep   0x03, 986
        intf    2, 0, 2, 0xff, 0                  | the vendor interface
        bulkep  0x02
        bulkep  0x82
        .byte   8, 11, 3, 2, 1, 1, 0, 0           | association: interfaces 3..4, audio
        intf    3, 0, 0, 1, 1                     | audio control
        .byte   9, 0x24, 1, 0, 1, 9, 0, 1, 4      | its header: ADC 1.0, 9 bytes, one streaming interface, 4
        intf    4, 0, 2, 1, 3                     | MIDI streaming
        .byte   7, 0x24, 1, 0, 1, 0x41, 0         | its header: MS 1.0, 65 bytes
        .byte   6, 0x24, 2, 1, 1, 0               | MIDI IN jack, embedded, 1
        .byte   6, 0x24, 2, 2, 2, 0               | MIDI IN jack, external, 2
        .byte   9, 0x24, 3, 1, 3, 1, 2, 1, 0      | MIDI OUT jack, embedded, 3 <- 2
        .byte   9, 0x24, 3, 2, 4, 1, 1, 1, 0      | MIDI OUT jack, external, 4 <- 1
        bulkep  0x01
        .byte   5, 0x25, 1, 1, 1                  | its jack: 1
        bulkep  0x81
        .byte   5, 0x25, 1, 1, 3                  | its jack: 3
cfg_end:

        | ------------------------------------------------------------------
        | v2. The packer's gap path (0x40005932): d0 = the frame number expected (the last + 1),
        | d1 = this packet's (the controller's, from the dTD); they differ, so frames went by with
        | no packet (a host that stopped polling: an OT re-enumerating on the hub). Stock moves the
        | reader and the count by 48 whatever the gap, so the audio of every frame past the first
        | goes uncounted and the lead moves by 48 a frame, into whole rings off (docs/rytm/mods.md).
        | Ten channels: skip the audio of every frame missed, plus the servo's frames owed, and count
        | it; no re-set from the writer after a long gap (the lead is kept). Free: d2-d7, a0-a6.
        | ------------------------------------------------------------------
        .section .u10g,"ax"
        .align  2
gap_gate:
        lea     RING_WR,%a0
        moveq   #10,%d2
        cmp.l   O_COUNT(%a0),%d2
        bne.s   9f                                | fewer channels: stock
        tst.l   O_RESYNC(%a0)
        bne.s   9f                                | a stream's start: stock, the re-set follows
        move.l  %d1,%d2
        sub.l   %d0,%d2
        andi.l  #2047,%d2                         | frames that sent no packet
        moveq   #48,%d3
        mulu.l  %d3,%d2                           | their audio
        add.l   O_SERVO(%a0),%d2                  | and the servo's frames owed meanwhile
        bpl.s   1f
        moveq   #0,%d2
1:      clr.l   O_SERVO(%a0)
        clr.l   O_SOFS(%a0)                       | counted: no re-set after a long gap
        add.l   %d2,O_FRAMES(%a0)                 | the header's count shows them
        add.l   O_RD(%a0),%d2
        moveq   #112,%d3
        add.l   %d3,%d3                           | RING_N
        remu.l  %d3,%d4:%d2                       | (Dw = Dx would be divu.l: the quotient)
        move.l  %d4,O_RD(%a0)                     | the reader skips them
        jmp     GAP_DONE
9:      move.l  RING_RD,%d0                       | displaced
        jmp     GAP_STOCK

        | ------------------------------------------------------------------
        | v2. lead_guard, from pack10 before it reads: the writer's lead RING_WR - RING_RD (1..224,
        | 224 = a whole ring) back to LEAD_T if it is under LEAD_LO or over LEAD_HI. Forward, the
        | frames skipped are counted (the running count and this packet's header, at d1 - 4); back,
        | the counter cannot run backwards, so the frames repeat uncounted. Keeps d1, d6, d7, a3;
        | uses d2-d5, a0, a1 (pack10's own scratch).
        | ------------------------------------------------------------------
        .section .u10l,"ax"
        .align  2
lead_guard:
        lea     RING_WR,%a0
        moveq   #112,%d4
        add.l   %d4,%d4                           | RING_N
        move.l  (%a0),%d5
        sub.l   O_RD(%a0),%d5
        bgt.s   0f
        add.l   %d4,%d5                           | the lead, 1..224
0:      moveq   #LEAD_LO,%d2
        cmp.l   %d2,%d5
        bcs.s   1f                                | too close to the writer
        cmpi.l  #LEAD_HI,%d5
        bls.s   9f                                | in the window: nothing
1:      moveq   #LEAD_T,%d2
        sub.l   %d2,%d5                           | the move: > 0 forward (skipped), < 0 back (repeated)
        move.l  O_RD(%a0),%d3
        add.l   %d5,%d3
        add.l   %d4,%d3
        remu.l  %d4,%d2:%d3                       | (Dw = Dx would be divu.l: the quotient)
        move.l  %d2,O_RD(%a0)
        tst.l   %d5
        ble.s   9f                                | a step back: nothing to count
        tst.l   O_HDR(%a0)
        beq.s   9f
        add.l   %d5,O_FRAMES(%a0)                 | counted: the running count
        move.l  %d1,%a1
        add.l   %d5,-4(%a1)                       | and this packet's header
9:      rts
