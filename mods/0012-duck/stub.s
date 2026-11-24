        | Mod 0012 - DUCK: a track-keyed ducker on a page behind COMP (see mod.toml).
        |
        | With the FX track selected, press AMP (COMP) a second time for the DUCK page:
        |   SRC  the key track: OFF, BD SD RS CP BT LT MT HT CH OH CY CB
        |   DEP  depth: 127 pulls the other voices fully down (90 ~ -10 dB); hold a
        |        track's pad while turning it to set that track's own depth instead
        |        (0..127, scales DEP for its voice; 127 = full, 0 = never ducked)
        |   ATK  attack, 0 instant .. 127 ~85 ms (time constant)
        |   HLD  hold at full depth after a hit, 0 .. 170 ms
        |   REL  release, 5 ms .. ~2 s (time constant)
        | Kept in the kit (xynta patch, 2026-11-22): the FX track's two
        | parameter words no stock parameter uses, index 0 and index 29 (the kit's
        | bytes 0x814-0x815 and 0x7f2-0x7f3; zero in every kit we know, saved, loaded,
        | copied and kept by the stock OS like any FX parameter). So DUCK changes with
        | the kit (a pattern change loads it), survives a power cycle with the working
        | kit, and goes to the +Drive with the project. Stored XOR the defaults, so a
        | kit that never had DUCK (all zero) reads SRC OFF, DEP 90, ATK 3, HLD 22,
        | REL 36. See dk_* below.
        |
        | The engine. The audio interrupt calls vca_frame(frame) once a block
        | (0x40119e0e, `jsr 0x40102960`): for each voice it smooths level x pan and
        | writes the VCA L / R words, frame +10+2v and +26+2v (u16, linear in
        | amplitude: PAN keeps L + R constant, VOL is a square law in the stock code).
        | The words are rewritten from the routine's own smoothed state (0x405fbab0)
        | every call, so scaling them afterwards never accumulates. That call's
        | operand is repointed at duck_gate, which makes it and then scales every
        | voice but the key's.
        |
        | The key (v4, xynta): the source track's note flag (NOTE_FLAGS),
        | set for a track with a new note in this block and cleared at the block's end:
        | the duck starts in the block the note starts. Upstream keyed on the voice's
        | audio in the receive frames (-36 dBFS, re-armed below -48), ~6.7 ms late.
        | Each ducked voice is scaled by its owner track's own depth (dk_amt_isr).
        |
        | The page. Page 12, listed after COMP (page 10) in the COMP view; five dead
        | Error records (ids 7, 8, 9, 14, 15) as its knobs. The four page hooks are
        | shared with 0010's page behind AMP: each gate here is the first link of a
        | chain (registry chain_pos -1) and passes any other page or id on through
        | CHAIN_* - 0010's gate when 0010 is in the build, else its own stock path
        | (the *_stock labels, which replay the displaced instructions).

        .include "symbols.inc"
        .include "shared.inc"

        .equ    PAGE_COMP,      10
        .equ    PAGE_DUCK,      12

        .equ    VCA_FN,         0x40102960
        .equ    RX_BASE,        0x8000cf34
        .equ    RX_IDX,         0x402acd70
        .equ    RX_STRIDE,      40                | 10 longs: voices 0..7, IN L/R
        .equ    FRAMES,         32

        .equ    DEP_K,          516               | DEP * 516 = depth, Q16
        | v4 (xynta): the key is the source track's own note flag, which the
        | audio interrupt sets for a track that gets a new note in this block (pads,
        | sequencer, MIDI, retrigs; not a muted track) and clears at the block's end,
        | after this runs (0x40119c08 reads it, 0x40119f2e clears it): no latency.
        .equ    NOTE_FLAGS,     0x8000a9e8        | long per track, 1 = a new note this block
        | v4: each track's own depth, 0..127 (127 = full), in its sound's spare byte:
        | sound word 0 bits 8..14 (kit byte 0x6e of the sound), stored XOR 127 so a
        | sound that never had it ducks fully. 0010's CHR keeps bits 0..6.
        .equ    PAD0,           0x90              | the BD pad's key id; the 12 pads follow
        .equ    SOUND0,         232+96            | project -> the kit's first track accessor
        .equ    SOUND_STRIDE,   352
        .equ    SOUND_LIVE,     16
        .equ    OFF_PARAMS,     0x14              | live sound: word 0

        .equ    S_ENV,          0                 | Q16, 0..65536
        .equ    S_HOLD,         4                 | blocks
        .equ    S_ARMED,        8

        | the settings, by byte
        .equ    G_SRC,          0
        .equ    G_DEP,          1
        .equ    G_ATK,          2
        .equ    G_HLD,          3
        .equ    G_REL,          4
        .equ    KNOBS,          5

        | the storage (dk_*): the active kit's FX parameter words
        .equ    KIT_FXPARAMS,   232+0x1240        | project + 232 = the kit; kit + 0x1240 -> the FX
                                                  | track's live parameter words, by index (emulator,
                                                  | 2026-11-22: index 0 here, index 29 at +58)
        .equ    W29,            58                | index 29's word
        .equ    FX_TRACK,       12                | the FX track in the kit's parameter bank
        .equ    ID_W0,          1                 | a record with index 0 (0010's CHR; no FX use)
        .equ    ID_W29,         53                | a record with index 29 (filter REL; no FX use)
        .equ    VT_PARAMSET,    160               | the view's vtable: its parameter set (0000)

        .globl  pi_stock, get_stock, delta_stock, text_stock   | chain fallbacks: build.py --defsym
        .text

        | ==================================================================
        | The engine
        | ==================================================================
        .align  2
duck_gate:
        move.l  4(%sp),-(%sp)
        jsr     VCA_FN
        addq.l  #4,%sp
        lea     -20(%sp),%sp
        movem.l %d2-%d5/%a2,(%sp)
        lea     dk_state,%a2
        lea     dk_set,%a1
        bsr.w   dk_load                           | the active kit's settings into dk_set
        mvz.b   G_SRC(%a1),%d0
        bne.s   10f
        clr.l   S_ENV(%a2)                        | OFF: nothing to do
        clr.l   S_HOLD(%a2)
        bra.w   99f
10:     lea     src_voice-1,%a0
        mvz.b   (%a0,%d0.l),%d5                   | d5 = the key's voice

        | the key: a new note on the source track in this block
        lea     NOTE_FLAGS-4,%a0
        lsl.l   #2,%d0                            | SRC 1..12 -> track 0..11, by 4
        moveq   #1,%d1
        cmp.l   (%a0,%d0.l),%d1
        bne.s   5f
        mvz.b   G_HLD(%a1),%d0                    | a note: full depth for HLD
        add.l   %d0,%d0                           | 2 blocks a step
        addq.l  #1,%d0
        move.l  %d0,S_HOLD(%a2)
        | attack while held
5:      move.l  S_ENV(%a2),%d0
        tst.l   S_HOLD(%a2)
        beq.s   6f
        subq.l  #1,S_HOLD(%a2)
        mvz.b   G_ATK(%a1),%d3
        addq.l  #1,%d3                            | time constant, blocks
        move.l  #65536,%d1
        sub.l   %d0,%d1
        divu.l  %d3,%d1                           | (1 - env) / (ATK + 1)
        bne.s   51f
        move.l  #65536,%d0                        | the last step
        bra.s   7f
51:     add.l   %d1,%d0
        bra.s   7f
        | release: env -= env / N, N = 8 + REL^2 / 5 blocks
6:      tst.l   %d0
        beq.s   7f
        mvz.b   G_REL(%a1),%d3
        mulu.w  %d3,%d3
        divu.w  #5,%d3
        mvz.w   %d3,%d3
        addq.l  #8,%d3
        move.l  %d0,%d1
        divu.l  %d3,%d1
        bne.s   61f
        moveq   #1,%d1                            | the last steps: one at a time
61:     sub.l   %d1,%d0
7:      move.l  %d0,S_ENV(%a2)
        beq.s   99f                               | no duck: leave the frame alone

        | depth * env, Q16; each voice but the key's by its owner track's own depth:
        | g = 1 - depth * env * amount / 128
        mvz.b   G_DEP(%a1),%d4
        mulu.w  #DEP_K,%d4                        | depth, Q16
        mulu.l  %d0,%d4
        clr.w   %d4
        swap    %d4
        move.l  24(%sp),%a2                       | the frame
        lea     10(%a2),%a2                       | VCA L, voice 0
        moveq   #0,%d3                            | voice
8:      cmp.l   %d5,%d3
        beq.s   9f
        bsr.w   dk_amt_isr                        | d0 = this voice's amount, 0..128
        mulu.l  %d4,%d0
        lsr.l   #7,%d0
        move.l  #65536,%d2
        sub.l   %d0,%d2                           | g, Q16
        mvz.w   (%a2),%d0
        mulu.l  %d2,%d0
        clr.w   %d0
        swap    %d0
        move.w  %d0,(%a2)
        mvz.w   16(%a2),%d0                       | VCA R, +26
        mulu.l  %d2,%d0
        clr.w   %d0
        swap    %d0
        move.w  %d0,16(%a2)
9:      addq.l  #2,%a2
        addq.l  #1,%d3
        moveq   #8,%d0
        cmp.l   %d0,%d3
        bne.s   8b
99:     movem.l (%sp),%d2-%d5/%a2
        lea     20(%sp),%sp
        rts

        | ==================================================================
        | The page
        | ==================================================================

        | page_info(id): page 12 is ours.
        .align  2
pi_gate:
        moveq   #PAGE_DUCK,%d0
        cmp.l   4(%sp),%d0
        bne.s   1f
        lea     page_duck,%a0
        move.l  %a0,%d0
        rts
1:      jmp     CHAIN_PI
        .align  2
pi_stock:
        moveq   #10,%d1                           | displaced
        move.l  %sp@(4),%d0                       | displaced
        jmp     page_info_resume

        | page_get_value: (%sp) return, 4 view, 8 id, 12 lock -> 8.8, 0..127 scale
        .align  2
get_gate:
        move.l  8(%sp),%d0
        bsr.w   knob_of                           | d0 = knob, or -1
        bmi.s   1f
        bsr.w   knob_value
        lsl.l   #8,%d0
        rts
1:      jmp     CHAIN_GET
        .align  2
get_stock:
        lea     %sp@(-12),%sp                     | displaced
        moveml  %d2-%d3/%a2,%sp@                  | displaced
        jmp     page_get_value_body

        | param_apply_delta past its prologue: %sp@(0..11) d2/d3/a2, a2 the view,
        | %sp@(20) the id, %sp@(24) the delta in 8.8
        .align  2
delta_gate:
        move.l  %sp@(20),%d0
        bsr.w   knob_of
        bmi.s   9f
        move.l  %d0,%d3                           | the knob
        move.l  %sp@(24),%d2
        asr.l   #8,%d2                            | whole steps
        beq.s   7f
        move.l  %d3,%d0
        bsr.w   knob_value
        add.l   %d2,%d0
        bpl.s   1f
        clr.l   %d0
1:      lea     knob_max,%a0
        mvz.b   (%a0,%d3.l),%d1
        cmp.l   %d1,%d0
        ble.s   2f
        move.l  %d1,%d0
2:      moveq   #G_DEP,%d1
        cmp.l   %d1,%d3
        bne.s   3f
        move.l  %d0,-(%sp)                        | a pad held: that track's own depth
        bsr.w   dk_pad
        move.l  %d0,%d1
        move.l  (%sp)+,%d0
        tst.l   %d1
        bmi.s   3f
        bsr.w   dk_store_amt                      | d1 the track, d0 its depth
        bra.s   4f
3:      bsr.w   dk_store                          | d3 the knob, d0 its value: into the kit
4:      move.l  %a2,-(%sp)
        jsr     view_invalidate                   | redraw now
        addq.l  #4,%sp
7:      movem.l (%sp),%d2-%d3/%a2                 | param_apply_delta's epilogue
        lea     12(%sp),%sp
        rts
9:      jmp     CHAIN_DELTA
        .align  2
delta_stock:
        mvzb    %d3,%d3                           | displaced
        move.l  %a2@(116),-(%sp)                  | displaced
        jmp     param_apply_delta_track

        | param_value_text past its argument loads: %sp@(0..19) d2-d4/a2-a3, d4 the
        | id, %sp@(36) the output buffer
        .align  2
text_gate:
        move.l  %d4,%d0
        bsr.w   knob_of
        bmi.s   9f
        move.l  %d0,%d1
        bsr.w   knob_value
        move.l  %sp@(36),%a1
        tst.l   %d1
        bne.s   2f
        lea     src_names,%a0                     | SRC: the track's name
        lsl.l   #2,%d0
        add.l   %d0,%a0
1:      move.b  (%a0)+,%d1
        beq.s   3f
        move.b  %d1,(%a1)+
        bra.s   1b
2:      bsr.w   put_u3
3:      clr.b   (%a1)
        movem.l (%sp),%d2-%d4/%a2-%a3             | param_value_text's epilogue
        lea     20(%sp),%sp
        rts
9:      jmp     CHAIN_TEXT
        .align  2
text_stock:
        movel   %sp@(32),%d2                      | displaced
        movel   %sp@(36),%d3                      | displaced
        jmp     param_value_text_args

        | knob_of(d0 = id) -> d0 = knob 0..4 or -1 (flags set). Clobbers a0.
        .align  2
knob_of:
        lea     knob_ids,%a0
        move.l  %d1,-(%sp)
        moveq   #0,%d1
1:      cmp.w   (%a0)+,%d0
        beq.s   2f
        addq.l  #1,%d1
        cmp.l   #KNOBS,%d1
        bne.s   1b
        moveq   #-1,%d1
2:      move.l  %d1,%d0
        move.l  (%sp)+,%d1
        tst.l   %d0
        rts

        | knob_value(d0 = knob) -> d0 = its setting; with a pad held, DEP answers that
        | track's own depth. Keeps d1/a1 (text_gate needs d1). Clobbers a0.
knob_value:
        move.l  %d1,-(%sp)
        move.l  %a1,-(%sp)
        moveq   #G_DEP,%d1
        cmp.l   %d1,%d0
        bne.s   5f
        bsr.w   dk_pad
        bmi.s   4f
        bsr.w   dk_track_amt
        bra.s   9f
4:      moveq   #G_DEP,%d0
5:      lea     dk_set,%a0
        mvz.b   (%a0,%d0.l),%d0
9:      move.l  (%sp)+,%a1
        move.l  (%sp)+,%d1
        rts

        | put_u3(d0 = 0..127, a1 = out) - decimal, no leading zeros, a1 past it.
        | Clobbers d0.
put_u3:
        move.l  %d1,-(%sp)
        moveq   #100,%d1
        cmp.l   %d1,%d0
        bcs.s   1f
        sub.l   %d1,%d0
        move.b  #0x31,(%a1)+                      | at most 127: the hundreds are 1
        divu.w  #10,%d0
        bra.s   2f
1:      divu.w  #10,%d0
        tst.w   %d0
        beq.s   3f
2:      move.l  %d0,%d1
        add.l   #0x30,%d1
        move.b  %d1,(%a1)+
3:      swap    %d0
        add.l   #0x30,%d0
        move.b  %d0,(%a1)+
        move.l  (%sp)+,%d1
        rts

        | ==================================================================
        | The settings in the kit (xynta patch). Placed in .tab (the
        | tail of cave2) for room.
        |
        | w0 = FX index 0, w29 = FX index 29, E = REL ^ 36:
        |   w0  bits 0..3 SRC, 4..7 E bits 0..3, 8..14 DEP ^ 90, 15 E bit 4
        |   w29 bits 0..6 ATK ^ 3, 7 E bit 5, 8..14 HLD ^ 22, 15 E bit 6
        | SRC sits whole in one word, so the audio interrupt never reads a source
        | half written; the one value split over both words is REL.
        | ==================================================================
        | dk_array() -> d0 = a0 = the active kit's FX parameter words, or 0 (flags).
        | (In .text: .tab is full.)
        .align  2
dk_array:
        move.l  project_instance,%d0
        beq.s   1f
        move.l  %d0,%a0
        move.l  KIT_FXPARAMS(%a0),%d0
1:      move.l  %d0,%a0
        tst.l   %d0
        rts

        .section .tab,"ax"

        | dk_load(a1 = dk_set): the active kit's settings into dk_set (nothing
        | without a kit). Clobbers d0-d2, d5, a0.
        .align  2
dk_load:
        bsr.w   dk_array
        bne.s   dk_decode
        rts

        | dk_decode(a0 = the words, a1 = 5 bytes out). Clobbers d0-d2, d5.
        .align  2
dk_decode:
        mvz.w   (%a0),%d2                         | w0
        mvz.w   W29(%a0),%d5                      | w29
        moveq   #15,%d0
        and.l   %d2,%d0
        moveq   #12,%d1
        cmp.l   %d1,%d0
        bls.s   1f
        moveq   #0,%d0                            | not a track: OFF
1:      move.b  %d0,G_SRC(%a1)
        moveq   #0x7f,%d1
        move.l  %d2,%d0
        lsr.l   #8,%d0
        and.l   %d1,%d0
        eori.l  #90,%d0
        move.b  %d0,G_DEP(%a1)
        move.l  %d5,%d0
        and.l   %d1,%d0
        eori.l  #3,%d0
        move.b  %d0,G_ATK(%a1)
        move.l  %d5,%d0
        lsr.l   #8,%d0
        and.l   %d1,%d0
        eori.l  #22,%d0
        move.b  %d0,G_HLD(%a1)
        move.l  %d2,%d0                           | E: w0 bits 4..7
        lsr.l   #4,%d0
        moveq   #15,%d1
        and.l   %d1,%d0
        move.l  %d2,%d1                           | w0 bit 15 -> E bit 4
        lsr.l   #8,%d1
        lsr.l   #3,%d1
        andi.l  #16,%d1
        or.l    %d1,%d0
        move.l  %d5,%d1                           | w29 bit 7 -> E bit 5
        lsr.l   #2,%d1
        andi.l  #32,%d1
        or.l    %d1,%d0
        move.l  %d5,%d1                           | w29 bit 15 -> E bit 6
        lsr.l   #8,%d1
        lsr.l   #1,%d1
        andi.l  #64,%d1
        or.l    %d1,%d0
        eori.l  #36,%d0
        move.b  %d0,G_REL(%a1)
        rts

        | dk_encode(a1 = 5 bytes) -> d0 = w0, d1 = w29. Clobbers d2, d5.
        .align  2
dk_encode:
        mvz.b   G_REL(%a1),%d5
        eori.l  #36,%d5                           | E
        mvz.b   G_SRC(%a1),%d0
        moveq   #15,%d1
        and.l   %d5,%d1
        lsl.l   #4,%d1
        or.l    %d1,%d0
        mvz.b   G_DEP(%a1),%d1
        eori.l  #90,%d1
        lsl.l   #8,%d1
        or.l    %d1,%d0
        moveq   #16,%d1
        and.l   %d5,%d1
        lsl.l   #8,%d1
        lsl.l   #3,%d1
        or.l    %d1,%d0
        mvz.b   G_ATK(%a1),%d1
        eori.l  #3,%d1
        moveq   #32,%d2
        and.l   %d5,%d2
        lsl.l   #2,%d2
        or.l    %d2,%d1
        mvz.b   G_HLD(%a1),%d2
        eori.l  #22,%d2
        lsl.l   #8,%d2
        or.l    %d2,%d1
        moveq   #64,%d2
        and.l   %d5,%d2
        lsl.l   #8,%d2
        lsl.l   #1,%d2
        or.l    %d2,%d1
        rts

        | dk_store(d3 = knob, d0 = value, a2 = the page view): the knob's new value
        | into the active kit - the live words for the engine, and the kit's
        | parameter bank on the FX track (kit_param_changed, as stock's own setters
        | and 0010's CHR do), which is what gets saved. Decoded from the live words,
        | not from dk_set, which the audio interrupt rewrites every block. Keeps
        | d2-d5/a2/a3; clobbers d0/d1/a0/a1.
        .align  2
dk_store:
        lea     -28(%sp),%sp
        movem.l %d2-%d5/%a3,(%sp)                 | the 5-byte buffer at 20(%sp)
        move.l  %d0,%d4                           | the value
        bsr.w   dk_array
        beq.w   8f
        move.l  %a0,%a3                           | the live words
        lea     20(%sp),%a1
        bsr.w   dk_decode
        lea     20(%sp),%a1
        move.b  %d4,(%a1,%d3.l)
        bsr.w   dk_encode
        move.w  %d0,(%a3)
        move.w  %d1,W29(%a3)
        move.l  %d0,%d4                           | w0
        move.l  %d1,%d5                           | w29
        move.l  (%a2),%a0                         | the view's parameter set
        move.l  VT_PARAMSET(%a0),%a0
        move.l  #-1,-(%sp)
        move.l  %a2,-(%sp)
        jsr     (%a0)
        addq.l  #8,%sp
        tst.l   %d0
        beq.s   6f
        move.l  %d0,%a0
        move.l  4(%a0),%a3                        | the kit's parameter bank
        move.l  %d4,-(%sp)
        pea     ID_W0
        pea     FX_TRACK
        move.l  %a3,-(%sp)
        jsr     kit_param_changed
        lea     16(%sp),%sp
        move.l  %d5,-(%sp)
        pea     ID_W29
        pea     FX_TRACK
        move.l  %a3,-(%sp)
        jsr     kit_param_changed
        lea     16(%sp),%sp
6:      lea     20(%sp),%a0                       | shown at once
        lea     dk_set,%a1
        move.b  (%a0)+,(%a1)+
        move.b  (%a0)+,(%a1)+
        move.b  (%a0)+,(%a1)+
        move.b  (%a0)+,(%a1)+
        move.b  (%a0)+,(%a1)+
        bra.s   9f
8:      lea     dk_set,%a0                        | no kit yet: RAM only
        move.b  %d4,(%a0,%d3.l)
9:      movem.l (%sp),%d2-%d5/%a3
        lea     28(%sp),%sp
        rts

        | dk_amt_isr(d3 = voice) -> d0 = its owner track's depth, 0..128 (the
        | interrupt's path: no calls; 0010's coefs_build reads the sound word so).
        | Clobbers d0/d1/a0.
        .align  2
dk_amt_isr:
        lea     voice_owner,%a0
        mvz.b   (%a0,%d3.l),%d0
        moveq   #11,%d1
        cmp.l   %d1,%d0
        bhi.s   8f
        move.l  #SOUND_STRIDE,%d1
        mulu.l  %d1,%d0
        move.l  project_instance,%d1
        beq.s   8f
        add.l   %d1,%d0
        move.l  %d0,%a0
        move.l  SOUND0+SOUND_LIVE(%a0),%d0
        beq.s   8f
        move.l  %d0,%a0
        mvz.b   OFF_PARAMS(%a0),%d0               | word 0's high byte
        bra.s   dk_amt128
8:      moveq   #0,%d0                            | no sound: as stored 0 = full
dk_amt128:                                        | stored byte -> 0..128
        moveq   #0x7f,%d1
        and.l   %d1,%d0
        eor.l   %d1,%d0                           | 0..127
        move.l  %d0,%d1
        lsr.l   #6,%d1
        add.l   %d1,%d0                           | 127 -> 128
        rts

        .text

        | dk_pad() -> d0 = the track whose pad is held (0..11), or -1 (flags).
        | Clobbers d0/d1/a0/a1.
        .align  2
dk_pad:
        move.l  %d2,-(%sp)
        moveq   #0,%d2
1:      move.l  %d2,%d0
        add.l   #PAD0,%d0
        move.l  %d0,-(%sp)
        jsr     is_key_held
        addq.l  #4,%sp
        tst.l   %d0
        bne.s   2f
        addq.l  #1,%d2
        moveq   #12,%d0
        cmp.l   %d0,%d2
        bne.s   1b
        moveq   #-1,%d2
2:      move.l  %d2,%d0
        move.l  (%sp)+,%d2
        tst.l   %d0
        rts

        | dk_track_amt(d0 = track) -> d0 = its depth 0..127. Clobbers d1/a0/a1.
        .align  2
dk_track_amt:
        jsr     shared_sound_of
        beq.s   8f
        mvz.b   OFF_PARAMS(%a0),%d0
        bra.s   9f
8:      moveq   #0,%d0
9:      moveq   #0x7f,%d1
        and.l   %d1,%d0
        eor.l   %d1,%d0
        rts

        | dk_store_amt(d1 = track, d0 = depth 0..127, a2 = the page view): the
        | track's sound word 0, bits 8..14 (CHR's bits 0..6 kept), live and in the
        | kit's parameter bank (id 1 = sound index 0, as 0010 saves CHR).
        | Keeps d2-d4/a2/a3; clobbers d0/d1/a0/a1.
        .align  2
dk_store_amt:
        lea     -16(%sp),%sp
        movem.l %d2-%d4/%a3,(%sp)
        move.l  %d0,%d4
        move.l  %d1,%d3
        move.l  %d3,%d0
        jsr     shared_sound_of
        beq.s   9f
        mvz.w   OFF_PARAMS(%a0),%d0
        moveq   #0x7f,%d1
        and.l   %d1,%d0                           | CHR stays
        eor.l   %d4,%d1                           | depth XOR 127
        lsl.l   #8,%d1
        or.l    %d1,%d0
        move.w  %d0,OFF_PARAMS(%a0)
        move.l  %d0,%d2
        move.l  (%a2),%a0                         | the view's parameter set -> bank
        move.l  VT_PARAMSET(%a0),%a0
        move.l  #-1,-(%sp)
        move.l  %a2,-(%sp)
        jsr     (%a0)
        addq.l  #8,%sp
        tst.l   %d0
        beq.s   9f
        move.l  %d0,%a0
        move.l  4(%a0),%a3
        move.l  %d2,-(%sp)
        pea     ID_W0
        move.l  %d3,-(%sp)
        move.l  %a3,-(%sp)
        jsr     kit_param_changed
        lea     16(%sp),%sp
9:      movem.l (%sp),%d2-%d4/%a3
        lea     16(%sp),%sp
        rts

        | ==================================================================
        | Data
        | ==================================================================
        .align  4
duck_pages:     .long   PAGE_COMP, PAGE_DUCK      | the COMP view's pages
page_duck:      .long   str_page                  | {name, top row, bottom row}
                .long   7, 8, 9, 14
                .long   15, 0, 0, 0
dk_state:       .long   0, 0, 1                   | env, hold, armed
knob_ids:       .short  7, 8, 9, 14, 15
knob_max:       .byte   12, 127, 127, 127, 127
dk_set:         .byte   0, 90, 3, 22, 36          | SRC DEP ATK HLD REL (defaults)
src_voice:      .byte   0, 2, 7, 7, 1, 3, 5, 5, 4, 4, 6, 6  | BD SD RS CP BT LT MT HT CH OH CY CB
src_names:      .ascii  "OFF\0BD\0\0SD\0\0RS\0\0CP\0\0BT\0\0LT\0\0MT\0\0HT\0\0CH\0\0OH\0\0CY\0\0CB\0\0"
str_page:       .asciz  "DUCK"
str_group:      .asciz  "DUCK"
str_src_l:      .asciz  "Duck Source"
str_src:        .asciz  "SRC"
str_dep_l:      .asciz  "Duck Depth"
str_dep:        .asciz  "DEP"
str_atk_l:      .asciz  "Duck Attack"
str_atk:        .asciz  "ATK"
str_hld_l:      .asciz  "Duck Hold"
str_hld:        .asciz  "HLD"
str_rel_l:      .asciz  "Duck Release"
str_rel:        .asciz  "REL"
