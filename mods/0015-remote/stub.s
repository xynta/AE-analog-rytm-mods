        | Mod 0015 - GHOST REMOTE for the Rytm MKI OS 1.74 (xynta, 2026-11-22; mod.toml says what).
        |
        | Entry: the Rytm's SysEx command table entry 0x5F (0x4024a434, a registry patch) -> ghr_entry, called by the
        | OS's SysEx router (0x40082104) as handler(msg, len, flags): msg = the whole message from F0, len its length
        | with F7, flags the source (8 DIN, 2 USB; 0x4008353e turns them into the reply port).
        |
        | Stock facts this relies on (OS 1.74, measured in analog-emu with breakpoints, docs/rytm/mods.md section 15):
        |   0x40083382  SysEx writer ctor (obj, 0, port); 0x40083358 put a byte (obj, byte); 0x400832b0 flush and
        |               close. The dump replies use exactly this (0x40084ae2). obj is 536 bytes.
        |   0x400803aa  the panel parser's key group handler (group, mask): edges against KEY_MASKS[group], an event
        |               per edge into the UI queue, then KEY_MASKS[group] = mask. 0x40080618 (channel, delta): the
        |               encoder handler. Both normally run in the panel UART's interrupt.
        |   0x405666e0  long: the sequencer plays; 0x40566754 byte: active pattern, +1 the queued one.
        |   0x40155738  -> the project; 0x400ab772(project) -> an object whose vtable +108 gives the active kit.
        |   0x4024bbb8  -> the framebuffer on glass (4 x 128 bytes): the LCD flush sends *0x4024bbb4, then swaps
        |               the two pointers, so *0x4024bbb4 is the next frame being drawn (up to ~250 ms behind).

        .equ    PORT_OF,        0x4008353e
        .equ    W_CTOR,         0x40083382
        .equ    W_PUT,          0x40083358
        .equ    W_DONE,         0x400832b0
        .equ    KEY_GROUP,      0x400803aa
        .equ    ENC_TURN,       0x40080618
        .equ    KEY_MASKS,      0x40a9e568
        .equ    PLAYING,        0x405666e0
        .equ    PATTERN,        0x40566754
        .equ    PROJECT,        0x40155738
        .equ    PROJ_OBJ,       0x400ab772
        .equ    FB_GLASS,       0x4024bbb8
        .equ    SLOTS,          80              | slots 0..79: key groups 0..9 (the panel's)

        .equ    OBJ,            -1080           | writer object, 536 bytes
        .equ    RAW,            -540            | raw payload, up to 520 bytes
        .equ    FRAME,          1120            | + 36 bytes of saved registers at the bottom

        .equ    ST_OK,          0
        .equ    ST_BAD,         2
        .equ    ST_UNKNOWN,     4

        .text

        .align  2
ghr_entry:
        link    %fp,#-FRAME
        movem.l %d2-%d7/%a2-%a4,(%sp)
        move.l  8(%fp),%a2                      | the message
        move.l  12(%fp),%d2
        moveq   #10,%d0
        cmp.l   %d0,%d2
        blt.w   ghr_out                         | no room for sub and seq: not ours to answer
        sub.l   %d0,%d2                         | d2 = argument bytes
        moveq   #0,%d6
        move.b  7(%a2),%d6                      | sub
        moveq   #0,%d7
        move.b  8(%a2),%d7                      | seq
        lea     9(%a2),%a4                      | arguments
        lea     RAW(%fp),%a3
        moveq   #0,%d4                          | payload length
        moveq   #ST_OK,%d5
        cmpi.b  #1,%d6
        beq.s   c_ping
        cmpi.b  #2,%d6
        beq.w   c_status
        cmpi.b  #3,%d6
        beq.w   c_key
        cmpi.b  #4,%d6
        beq.w   c_enc
        cmpi.b  #5,%d6
        beq.w   c_screen
        cmpi.b  #6,%d6
        beq.w   c_read
        cmpi.b  #12,%d6
        beq.w   c_release
        moveq   #ST_UNKNOWN,%d5
        bra.w   reply

        | -------- PING: protocol 1, version 1.0, the mods in this image (bit 0 0009 .. bit 5 0015)
c_ping:
        moveq   #0,%d1
        tst.b   0x4018d911                      | 0009: machine 36 offered
        beq.s   1f
        bset    #0,%d1
1:      move.l  0x4018e338,%d0                  | 0010: id 13's short name repointed
        cmpi.l  #0x401ff27d,%d0
        beq.s   3f
        bset    #1,%d1
3:      move.w  0x40118984,%d0                  | 0011: a jmp on the audio interrupt's entry
        cmpi.w  #0x4ef9,%d0
        bne.s   4f
        bset    #2,%d1
4:      move.l  0x40119e10,%d0                  | 0012: the audio interrupt's vca_frame call repointed
        cmpi.l  #0x40102960,%d0
        beq.s   5f
        bset    #3,%d1
5:      move.l  0x40236e48,%d0                  | 0014: the OVERBRIDGE descriptor repointed
        cmpi.l  #0x402a23be,%d0
        beq.s   6f
        bset    #4,%d1
6:      bset    #5,%d1                          | 0015: this
        move.b  #1,(%a3)+                       | protocol
        move.b  #1,(%a3)+                       | version 1.0
        clr.b   (%a3)+
        move.w  %d1,(%a3)+                      | mods, big endian
        moveq   #5,%d4
        bra.w   reply

        | -------- STATUS: layout 1, playing, pattern, queued, kit, 12 key masks
c_status:
        move.b  #1,(%a3)+
        tst.l   PLAYING
        sne     %d0
        andi.l  #1,%d0
        move.b  %d0,(%a3)+
        move.b  PATTERN,(%a3)+
        move.b  PATTERN+1,(%a3)+
        jsr     PROJECT
        move.l  %d0,-(%sp)
        jsr     PROJ_OBJ
        addq.l  #4,%sp
        move.l  %d0,%a0
        move.l  (%a0),%a1
        move.l  %d0,-(%sp)
        move.l  108(%a1),%a1
        jsr     (%a1)                           | the active kit
        addq.l  #4,%sp
        move.b  %d0,(%a3)+
        lea     KEY_MASKS,%a0
        moveq   #11,%d0
1:      move.b  (%a0)+,(%a3)+
        subq.l  #1,%d0
        bpl.s   1b
        moveq   #17,%d4
        bra.w   reply

        | -------- KEY slot down: one edge on the panel's key path
c_key:
        moveq   #2,%d0
        cmp.l   %d0,%d2
        bne.w   bad
        moveq   #0,%d3
        move.b  (%a4),%d3                       | slot
        cmpi.l  #SLOTS,%d3
        bcc.w   bad
        move.b  1(%a4),%d1
        cmpi.b  #1,%d1
        bhi.w   bad
        move.l  %d3,%d6
        lsr.l   #3,%d6                          | group
        andi.l  #7,%d3                          | bit
        move.w  %sr,%d7
        move.w  #0x2700,%sr
        lea     KEY_MASKS,%a0
        moveq   #0,%d0
        move.b  (%a0,%d6.l),%d0
        bclr    %d3,%d0
        tst.b   %d1
        beq.s   1f
        bset    %d3,%d0
1:      move.l  %d0,-(%sp)
        move.l  %d6,-(%sp)
        jsr     KEY_GROUP
        addq.l  #8,%sp
        move.w  %d7,%sr
        moveq   #0,%d7
        move.b  8(%a2),%d7                      | seq again (d7 lent for SR)
        moveq   #3,%d6
        bra.w   reply

        | -------- ENC channel delta: a turn on the panel's encoder path
c_enc:
        moveq   #2,%d0
        cmp.l   %d0,%d2
        bne.w   bad
        moveq   #0,%d3
        move.b  (%a4),%d3                       | channel 0..8
        cmpi.l  #8,%d3
        bhi.w   bad
        moveq   #0,%d1
        move.b  1(%a4),%d1                      | delta, 7-bit signed
        btst    #6,%d1
        beq.s   1f
        subi.l  #128,%d1
1:      tst.l   %d1
        beq.w   bad
        move.w  %sr,%d7
        move.w  #0x2700,%sr
        move.l  %d1,-(%sp)
        move.l  %d3,-(%sp)
        jsr     ENC_TURN
        addq.l  #8,%sp
        move.w  %d7,%sr
        moveq   #0,%d7
        move.b  8(%a2),%d7
        moveq   #4,%d6
        bra.w   reply

        | -------- SCREEN: the framebuffer on glass
c_screen:
        move.l  FB_GLASS,%a0
        move.l  #127,%d0
1:      move.l  (%a0)+,(%a3)+
        subq.l  #1,%d0
        bpl.s   1b
        move.l  #512,%d4
        bra.w   reply

bad:
        moveq   #ST_BAD,%d5
        moveq   #0,%d4

        | -------- the reply: header, status, the payload 8-in-7, F7
reply:
        move.l  16(%fp),-(%sp)
        jsr     PORT_OF
        addq.l  #4,%sp
        move.l  %d0,-(%sp)
        clr.l   -(%sp)
        pea     OBJ(%fp)
        jsr     W_CTOR
        lea     12(%sp),%sp
        lea     ghr_hdr,%a4
        moveq   #6,%d3
1:      moveq   #0,%d0
        move.b  (%a4)+,%d0
        bsr.w   put
        subq.l  #1,%d3
        bpl.s   1b
        move.l  %d6,%d0
        ori.l   #0x40,%d0
        bsr.w   put
        move.l  %d7,%d0
        bsr.w   put
        move.l  %d5,%d0
        bsr.w   put
        lea     RAW(%fp),%a3
2:      tst.l   %d4                             | groups of 7: their top bits first
        ble.s   6f
        moveq   #0,%d0
        moveq   #0,%d3
3:      cmp.l   %d3,%d4
        ble.s   4f
        moveq   #7,%d1
        cmp.l   %d1,%d3
        beq.s   4f
        move.b  (%a3,%d3.l),%d1
        btst    #7,%d1
        beq.s   31f
        moveq   #6,%d1
        sub.l   %d3,%d1
        bset    %d1,%d0
31:     addq.l  #1,%d3
        bra.s   3b
4:      bsr.s   put
        moveq   #0,%d3
5:      cmp.l   %d3,%d4
        ble.s   51f
        moveq   #7,%d1
        cmp.l   %d1,%d3
        beq.s   51f
        moveq   #0,%d0
        move.b  (%a3,%d3.l),%d0
        andi.l  #0x7f,%d0
        bsr.w   put
        addq.l  #1,%d3
        bra.s   5b
51:     lea     7(%a3),%a3
        subq.l  #7,%d4
        bra.s   2b
6:      move.l  #0xf7,%d0
        bsr.w   put
        pea     OBJ(%fp)
        jsr     W_DONE
        addq.l  #4,%sp
ghr_out:
        movem.l (%sp),%d2-%d7/%a2-%a4
        unlk    %fp
        rts

put:                                            | d0 = a byte; keeps d2-d7, a2-a4
        move.l  %d0,-(%sp)
        pea     OBJ(%fp)
        jsr     W_PUT
        addq.l  #8,%sp
        rts

        | ---------------------------------------- the second cave (MT TEST's routine): READ, RELEASE, data
        .section .ghr2,"ax"
        .align  2
        | -------- READ addr(5 x 7 bits) n(2 x 7 bits): 1..256 bytes of DDR, SRAM or CS1
c_read:
        moveq   #7,%d0
        cmp.l   %d0,%d2
        bne.w   bad
        moveq   #0,%d3
        moveq   #4,%d1
1:      lsl.l   #7,%d3
        moveq   #0,%d0
        move.b  (%a4)+,%d0
        or.l    %d0,%d3
        subq.l  #1,%d1
        bpl.s   1b                              | d3 = address
        moveq   #0,%d4
        move.b  (%a4)+,%d4
        lsl.l   #7,%d4
        moveq   #0,%d0
        move.b  (%a4),%d0
        or.l    %d0,%d4                         | d4 = length
        beq.w   bad
        cmpi.l  #256,%d4
        bhi.w   bad
        lea     ghr_ranges,%a0
        moveq   #2,%d1
2:      move.l  (%a0)+,%d0                      | lo
        move.l  (%a0)+,%d2                      | hi
        cmp.l   %d0,%d3
        bcs.s   3f
        move.l  %d3,%d0
        add.l   %d4,%d0
        cmp.l   %d2,%d0
        bls.s   4f
3:      subq.l  #1,%d1
        bpl.s   2b
        bra.w   bad
4:      move.l  %d3,(%a3)+
        move.l  %d3,%a0
        move.l  %d4,%d0
5:      move.b  (%a0)+,(%a3)+
        subq.l  #1,%d0
        bne.s   5b
        addq.l  #4,%d4
        bra.w   reply

        | -------- RELEASE: every group up
c_release:
        move.w  %sr,%d7
        move.w  #0x2700,%sr
        moveq   #0,%d3
1:      lea     KEY_MASKS,%a0
        tst.b   (%a0,%d3.l)
        beq.s   2f
        clr.l   -(%sp)
        move.l  %d3,-(%sp)
        jsr     KEY_GROUP
        addq.l  #8,%sp
2:      addq.l  #1,%d3
        moveq   #10,%d0
        cmp.l   %d0,%d3
        bne.s   1b
        move.w  %d7,%sr
        moveq   #0,%d7
        move.b  8(%a2),%d7
        moveq   #12,%d6
        bra.w   reply

        .align  2
ghr_ranges:
        .long   0x40000000, 0x48000000          | DDR
        .long   0x80000000, 0x80010000          | SRAM
        .long   0x20000000, 0x20200000          | CS1 (the persistent working state)
ghr_hdr:
        .byte   0xf0, 0x00, 0x20, 0x3c, 0x07, 0x00, 0x5f
