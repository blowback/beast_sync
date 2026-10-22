;==============================================================================
; SYNC.COM - start two CP/M programs in lockstep on two Z80 machines
;
;   SYNC <flags> <prog>[.ext] [args...]
;
;   flags (any order, any case, other letters ignored):
;     M  MicroBeast  - Z84C20 PIO, port A data 0x10 / control 0x12
;     N  NanoBeast   - CPLD, port A data 0x10 / direction 0x11 (always bit mode)
;     L  leader      - sends the heartbeat and the START pulse
;     F  follower    - echoes RX to TX, fires on the falling edge of START
;
;   <prog> defaults to .COM. Everything after it becomes the program's
;   command tail at 0x0080, and the first two words are parsed into the
;   default FCBs at 0x005C/0x006C, just as the CCP would have done.
;
; Wiring: TX(A) -> RX(B), TX(B) -> RX(A), GND. 1k series at each TX,
; 10k pull-down at each RX.
;
; How it works:
;   1. Parse the command line, set up the PIO, rebuild tail and FCBs.
;   2. Copy the resident stub to the top of the TPA (just under BDOS, on a
;      page boundary) and fix it up from the sjasmplus HIGH relocation table.
;   3. The stub loads <prog> at 0x0100, over the top of SYNC itself.
;   4. Follower: mirror RX onto TX. If RX stays high for longer than any
;      heartbeat can (ARM_US), that's START: DI, wait for the falling edge,
;      go.
;      Leader: raise TX, wait for the echo, hold HB_US, drop TX, wait for
;      the echo, hold HB_US. Any miss restarts the count. After BEATS good
;      round trips: DI, hold TX high for START_US, drop it, go.
;   5. Go: SP=(0x0006), push 0 so RET warm boots, restore the interrupt
;      state SYNC was started with, JP 0x0100.
;
; Any key aborts while waiting (the stub sits where the CCP was, so abort
; is a warm boot).
;
; Assemble: sjasmplus sync.asm   (writes sync.com)
;==============================================================================

        OUTPUT  "sync.com"

;--- configuration ------------------------------------------------------------

CPU_MHZ         EQU     8               ; both machines; all timings derive from this

TX_BIT          EQU     0               ; port A bit driven by this machine
RX_BIT          EQU     1               ; port A bit read from the other machine

PIO_DATA        EQU     0x10            ; port A data, same on both machines
MB_PIO_ACTRL    EQU     0x12            ; Z84C20 port A control (A0=B/A, A1=C/D)
NB_PIO_DIR      EQU     0x11            ; NanoBeast CPLD port A direction
NB_DIR_1_IS_INPUT EQU   1               ; 1 = a set bit means input (like the Z80 PIO)

HB_US           EQU     500             ; leader holds each heartbeat level this long after the echo
TO_US           EQU     2000            ; leader gives up waiting for an echo after this
RETRY_US        EQU     10000           ; leader sits low this long after a miss
ARM_US          EQU     4000            ; follower: RX high this long = START (rounded up below)
START_US        EQU     20000           ; length of the START pulse
ARMTO_US        EQU     100000          ; follower: give up if START never falls
BEATS           EQU     8               ; consecutive good round trips required
TRIM_NOPS       EQU     12              ; leader pad after the edge, ~= follower's detect latency

;--- derived ------------------------------------------------------------------

TX_MASK         EQU     1 << TX_BIT
RX_MASK         EQU     1 << RX_BIT
MB_DIR          EQU     0xFF & ~TX_MASK ; Z80 PIO mode 3: 1 = input
    IF NB_DIR_1_IS_INPUT
NB_DIR          EQU     0xFF & ~TX_MASK
    ELSE
NB_DIR          EQU     TX_MASK
    ENDIF

; T-states per iteration of each timing loop (see the loops themselves)
T_DELAY         EQU     26              ; s_delay
T_WAIT          EQU     53              ; s_wait_rx
T_FHIGH         EQU     72              ; follower loop while RX is high
T_ARM           EQU     38              ; follower loop waiting for the edge

HB_CNT          EQU     (HB_US*CPU_MHZ + T_DELAY-1) / T_DELAY
START_CNT       EQU     (START_US*CPU_MHZ + T_DELAY-1) / T_DELAY
RETRY_CNT       EQU     (RETRY_US*CPU_MHZ + T_DELAY-1) / T_DELAY
TO_CNT          EQU     (TO_US*CPU_MHZ + T_WAIT-1) / T_WAIT
ARM_H           EQU     ((ARM_US*CPU_MHZ + T_FHIGH-1) / T_FHIGH + 255) / 256
ARM_REAL_US     EQU     ARM_H*256*T_FHIGH / CPU_MHZ
ARMTO_OUTER     EQU     (ARMTO_US*CPU_MHZ) / (T_ARM*256)

        ASSERT  HB_CNT >= 1 && START_CNT <= 65535 && RETRY_CNT <= 65535 && TO_CNT <= 65535
        ASSERT  ARM_H >= 1 && ARMTO_OUTER >= 1 && ARMTO_OUTER <= 255
        ; Longest a heartbeat can stay high is TO + HB. Keep well clear of the arm threshold.
        ASSERT  ARM_REAL_US > TO_US + HB_US + 1000
        ; START must comfortably outlast the arm threshold.
        ASSERT  START_US > ARM_REAL_US + 5000

;--- CP/M ---------------------------------------------------------------------

WBOOT           EQU     0x0000
BDOS            EQU     0x0005
BDOS_ADDR       EQU     0x0006
FCB1            EQU     0x005C
FCB2            EQU     0x006C
TBUFF           EQU     0x0080
TPA             EQU     0x0100

C_RAWIO         EQU     6
C_WRITESTR      EQU     9
F_OPEN          EQU     15
F_READ          EQU     20
F_DMAOFF        EQU     26

;==============================================================================
; Transient part: runs once at 0x0100, then gets overwritten by <prog>
;==============================================================================

        ORG     TPA

start:
        LD      (saved_sp), SP
        LD      SP, init_stack_top

; Interrupt state at entry. LD A, I can give a false "disabled" if an
; interrupt is accepted during it, never a false "enabled", so ask twice.
        LD      A, I
        JP      PE, .ie_on
        LD      A, I
        JP      PE, .ie_on
        XOR     A
        JR      .ie_set
.ie_on: LD      A, 1
.ie_set:
        LD      (stub_image + s_ie), A

; Copy the tail somewhere safe: we rebuild 0x0080 and the FCBs from it.
        LD      HL, TBUFF
        LD      C, (HL)
        LD      B, 0
        INC     HL
        LD      DE, tailbuf
        LD      A, C
        OR      A
        JR      Z, .notail
        LDIR
.notail:
        XOR     A
        LD      (DE), A

;--- Argument parsing ---------------------------------------------------------------------
 
; --- first word: flags. D bit0=M bit1=N, E bit0=L bit1=F
        LD      HL, tailbuf
        CALL    skip_ws
        OR      A
        JP      Z, usage
        LD      DE, 0
.flag:  LD      A, (HL)
        OR      A
        JR      Z, .flags_done
        CP      ' '
        JR      Z, .flags_done
        CP      9
        JR      Z, .flags_done
        INC     HL
        CALL    upcase
        CP      'M'
        JR      NZ, .not_m
        SET     0, D
        JR      .flag
.not_m: CP      'N'
        JR      NZ, .not_n
        SET     1, D
        JR      .flag
.not_n: CP      'L'
        JR      NZ, .not_l
        SET     0, E
        JR      .flag
.not_l: CP      'F'
        JR      NZ, .flag
        SET     1, E
        JR      .flag

.flags_done:
        LD      A, E
        CP      1                       ; leader
        JR      Z, .role_ok
        CP      2                       ; follower
        JR      Z, .role_ok
        LD      DE, msg_role
        JP      error
.role_ok:
        AND     1                       ; 1 = leader, 0 = follower
        LD      (stub_image + s_role), A
        LD      A, D
        CP      1                       ; MicroBeast
        JR      Z, .mach_ok
        CP      2                       ; NanoBeast
        JR      Z, .mach_ok
        LD      DE, msg_mach
        JP      error
.mach_ok:
        LD      (machine), A

; --- second word: the program
        CALL    skip_ws
        OR      A
        JP      Z, usage
        LD      DE, stub_image + s_fcb
        CALL    parse_fcb
        LD      A, (stub_image + s_fcb + 1)
        CP      ' '
        JP      Z, usage
        LD      A, (stub_image + s_fcb + 9)
        CP      ' '
        JR      NZ, .has_ext
        PUSH    HL
        LD      HL, ext_com
        LD      DE, stub_image + s_fcb + 9
        LD      BC, 3
        LDIR
        POP     HL
.has_ext:

; --- the rest becomes the program's tail, verbatim (leading space and all)
        PUSH    HL
        LD      DE, TBUFF+1
        LD      B, 0
.tail:  LD      A, (HL)
        LD      (DE), A
        OR      A
        JR      Z, .tail_done
        INC     HL
        INC     DE
        INC     B
        JR      .tail
.tail_done:
        LD      A, B
        LD      (TBUFF), A

; --- and its first two words go into the default FCBs
        POP     HL
        CALL    skip_ws
        LD      DE, FCB1
        CALL    parse_fcb
        CALL    skip_ws
        LD      DE, FCB2
        CALL    parse_fcb
        XOR     A
        LD      (FCB1+32), A            ; current record

; --- PIO: TX low first, then make it the only output on port A
        LD      A, (machine)
        DEC     A
        JR      NZ, .nanobeast
        XOR     A
        OUT     (PIO_DATA), A           ; preload the output latch
        LD      A, 0xCF                 ; mode 3 (bit control)
        OUT     (MB_PIO_ACTRL), A
        LD      A, MB_DIR
        OUT     (MB_PIO_ACTRL), A
        LD      A, 0x07                 ; interrupt control: disabled
        OUT     (MB_PIO_ACTRL), A
        JR      .pio_done
.nanobeast:
        XOR     A
        OUT     (PIO_DATA), A
        LD      A, NB_DIR
        OUT     (NB_PIO_DIR), A
.pio_done:

; --- where does the stub go? Whole pages, ending at the BDOS page.
        LD      HL, (BDOS_ADDR)
        LD      L, 0
        LD      A, H
        SUB     STUB_PAGES
        LD      H, A
        JR      C, .no_room
        PUSH    HL
        LD      DE, init_end            ; can't overlap ourselves while relocating
        OR      A
        SBC     HL, DE
        POP     HL
        JR      NC, .room
.no_room:
        LD      DE, msg_tpa
        JP      error
.room:
        LD      (stub_dest), HL

; --- say what we're doing while BDOS still has a sane stack under it
        LD      A, (stub_image + s_role)
        OR      A
        LD      DE, msg_lead
        JR      NZ, .banner
        LD      DE, msg_follow
.banner:
        LD      C, C_WRITESTR
        CALL    BDOS

; --- copy and relocate. Nothing below may touch the stack area of the CCP:
;     ours is local, and from here there are no more BDOS calls.
        LD      DE, (stub_dest)
        LD      HL, stub_image
        LD      BC, STUB_SIZE
        LDIR

        LD      HL, reloc_table
        LD      BC, relocate_count
.reloc: LD      A, B
        OR      C
        JR      Z, .reloc_done
        LD      E, (HL)
        INC     HL
        LD      D, (HL)
        INC     HL
        PUSH    HL
        LD      HL, (stub_dest)
        ADD     HL, DE                  ; -> MSB of an address in the stub
        LD      A, (stub_dest+1)
        ADD     A, (HL)
        LD      (HL), A
        POP     HL
        DEC     BC
        JR      .reloc
.reloc_done:
        LD      HL, (stub_dest)
        JP      (HL)

;------------------------------------------------------------------------------

usage:  LD      DE, msg_usage
error:  LD      C, C_WRITESTR
        CALL    BDOS
        LD      SP, (saved_sp)
        RET                             ; CCP is still intact at this point

; skip spaces/tabs; return A = (HL)
skip_ws:
        LD      A, (HL)
        CP      ' '
        JR      Z, .next
        CP      9
        RET     NZ
.next:  INC     HL
        JR      skip_ws

upcase: CP      'a'
        RET     C
        CP      'z'+1
        RET     NC
        SUB     0x20
        RET

; Z if A is a filename delimiter (CCP's set plus tab and comma). Keeps HL, BC.
is_delim:
        PUSH    HL
        PUSH    BC
        LD      HL, delims
        LD      BC, DELIMS_N
        CPIR
        POP     BC
        POP     HL
        RET

; Parse [d:]name[.ext] at HL into the 16-byte FCB at DE, CCP style:
; blank-filled, upper case, '*' expands to '?'. Leaves HL on the delimiter.
parse_fcb:
        PUSH    DE
        XOR     A
        LD      (DE), A
        INC     DE
        LD      B, 11
        LD      A, ' '
.clr1:  LD      (DE), A
        INC     DE
        DJNZ    .clr1
        LD      B, 4
        XOR     A
.clr2:  LD      (DE), A
        INC     DE
        DJNZ    .clr2
        POP     DE

        LD      A, (HL)
        OR      A
        RET     Z
        INC     HL
        LD      A, (HL)
        DEC     HL
        CP      ':'
        JR      NZ, .name
        LD      A, (HL)
        CALL    upcase
        CP      'A'
        JR      C, .name
        CP      'P'+1
        JR      NC, .name
        SUB     'A'-1
        LD      (DE), A
        INC     HL
        INC     HL
.name:  INC     DE
        LD      B, 8
        CALL    .field
        LD      A, (HL)
        CP      '.'
        RET     NZ
        INC     HL
        LD      B, 3                    ; DE is at fcb+9 after the name field
.field: LD      A, (HL)
        CALL    is_delim
        JR      Z, .pad
        INC     HL
        CP      '*'
        JR      Z, .star
        CALL    upcase
        LD      (DE), A
        INC     DE
        DJNZ    .field
.skip:  LD      A, (HL)                 ; too long: drop the excess
        CALL    is_delim
        RET     Z
        INC     HL
        JR      .skip
.star:  LD      A, '?'
.st1:   LD      (DE), A
        INC     DE
        DJNZ    .st1
        JR      .skip
.pad:   INC     DE                      ; field already blank, just step over it
        DJNZ    .pad
        RET

;------------------------------------------------------------------------------

saved_sp:   DW  0
stub_dest:  DW  0
machine:    DB  0
ext_com:    DB  "COM"
delims:     DB  0, ' ', 9, '.', ':', ',', ';', '<', '>', '=', '_', '[', ']'
DELIMS_N    EQU $ - delims

msg_usage:
        DB      "Usage: SYNC <flags> <prog>[.COM] [args...]", 13, 10
        DB      "  flags: M = MicroBeast, N = NanoBeast (one of)", 13, 10
        DB      "         L = leader,     F = follower  (one of)", 13, 10
        DB      "  e.g.   SYNC ML GAME P1", 13, 10, "$"
msg_mach:   DB  "SYNC: flags need exactly one of M or N", 13, 10, "$"
msg_role:   DB  "SYNC: flags need exactly one of L or F", 13, 10, "$"
msg_tpa:    DB  "SYNC: TPA too small", 13, 10, "$"
msg_lead:   DB  "SYNC: leader, waiting for follower (any key aborts)", 13, 10, "$"
msg_follow: DB  "SYNC: follower, waiting for leader (any key aborts)", 13, 10, "$"

;==============================================================================
; Resident stub. Assembled at 0x0000, copied to a page boundary under BDOS and
; relocated by adding the page number to every address MSB in reloc_table.
;==============================================================================

stub_image:
        DISP    0
        RELOCATE_START HIGH

s_base:
        LD      SP, s_stack_top

; --- load <prog> at 0x0100
        LD      DE, s_fcb
        LD      C, F_OPEN
        CALL    BDOS
        INC     A
        JP      Z, s_err_nf
        LD      HL, TPA
.read:  PUSH    HL                      ; will this record fit under us?
        LD      DE, 128
        ADD     HL, DE
        EX      DE, HL
        LD      HL, s_base
        OR      A
        SBC     HL, DE
        POP     HL
        JP      C, s_err_big
        PUSH    HL
        EX      DE, HL
        LD      C, F_DMAOFF
        CALL    BDOS
        LD      DE, s_fcb
        LD      C, F_READ
        CALL    BDOS
        POP     HL
        OR      A
        JR      NZ, .loaded             ; EOF (or error: treat as end)
        LD      DE, 128
        ADD     HL, DE
        JR      .read
.loaded:
        LD      DE, TBUFF              ; the CCP leaves DMA at 0x0080
        LD      C, F_DMAOFF
        CALL    BDOS
        LD      A, (s_role)
        OR      A
        JP      NZ, s_leader

;--- follower ------------------------------------------------------------------

s_follower:
        LD      HL, 0                   ; HL: iterations RX has been high
        LD      D, H                    ; DE: idle iterations, for the abort check
        LD      E, L
.loop:  IN      A, (PIO_DATA)           ; 11
        AND     RX_MASK                 ;  7
        JR      Z, .low                 ;  7
        LD      A, TX_MASK              ;  7
        OUT     (PIO_DATA), A           ; 11
        INC     HL                      ;  6
        LD      A, H                    ;  4
        CP      ARM_H                   ;  7
        JR      C, .loop                ; 12  = 72T (T_FHIGH)

; RX has been high longer than any heartbeat: this is START. Commit.
        DI
        LD      C, ARMTO_OUTER
        LD      B, 0
.arm:   IN      A, (PIO_DATA)           ; 11
        AND     RX_MASK                 ;  7
        JR      Z, .fire                ;  7
        DJNZ    .arm                    ; 13  = 38T (T_ARM): edge jitter 0..38T
        DEC     C
        JR      NZ, .arm
        CALL    s_restore_ie            ; START never ended, stuck line: start over
        JR      s_follower
.fire:  XOR     A
        OUT     (PIO_DATA), A
        JP      s_go

.low:   XOR     A
        OUT     (PIO_DATA), A
        LD      H, A
        LD      L, A
        INC     DE
        LD      A, D
        OR      E
        JR      NZ, .loop
        CALL    s_chk_abort             ; every ~65536 idle passes, ~0.6s
        JR      s_follower

;--- leader --------------------------------------------------------------------

s_leader:
        LD      B, BEATS
.beat:  LD      A, TX_MASK
        OUT     (PIO_DATA), A
        LD      A, RX_MASK
        CALL    s_wait_rx               ; echo high?
        JR      C, .miss
        LD      HL, HB_CNT
        CALL    s_delay
        XOR     A
        OUT     (PIO_DATA), A
        CALL    s_wait_rx               ; A=0: echo low?
        JR      C, .miss
        LD      HL, HB_CNT
        CALL    s_delay
        DJNZ    .beat

; BEATS good round trips: send START.
        DI
        LD      A, TX_MASK
        OUT     (PIO_DATA), A
        LD      HL, START_CNT
        CALL    s_delay
        XOR     A
        OUT     (PIO_DATA), A           ; <-- the edge
        DUP     TRIM_NOPS
        NOP
        EDUP
        JP      s_go

.miss:  XOR     A
        OUT     (PIO_DATA), A
        CALL    s_chk_abort
        LD      HL, RETRY_CNT
        CALL    s_delay
        JR      s_leader

;--- shared --------------------------------------------------------------------

; Wait for (RX & RX_MASK) == A. NC on match, C on timeout. Uses A, C, HL.
s_wait_rx:
        LD      C, A
        LD      HL, TO_CNT
.l:     IN      A, (PIO_DATA)           ; 11
        AND     RX_MASK                 ;  7
        CP      C                       ;  4
        RET     Z                       ;  5
        DEC     HL                      ;  6
        LD      A, H                    ;  4
        OR      L                       ;  4
        JR      NZ, .l                  ; 12  = 53T (T_WAIT)
        SCF
        RET

; Busy-wait HL (>=1) passes of 26T (T_DELAY). Uses A, HL.
s_delay:
        DEC     HL                      ;  6
        LD      A, H                    ;  4
        OR      L                       ;  4
        JR      NZ, s_delay             ; 12
        RET

s_go:   LD      SP, (BDOS_ADDR)
        LD      HL, WBOOT               ; CCP is gone: RET means warm boot
        PUSH    HL
        LD      A, (s_ie)
        OR      A
        JR      Z, .go
        EI
.go:    JP      TPA

s_restore_ie:
        LD      A, (s_ie)
        OR      A
        RET     Z
        EI
        RET

; Any key aborts. BDOS 6/FFh: no echo, no ^C handling, consumes the key.
s_chk_abort:
        LD      E, 0xFF
        LD      C, C_RAWIO
        CALL    BDOS
        OR      A
        RET     Z
        XOR     A
        OUT     (PIO_DATA), A
        LD      DE, s_msg_abort
        JR      s_die
s_err_nf:
        LD      DE, s_msg_nf
        JR      s_die
s_err_big:
        LD      DE, s_msg_big
s_die:  LD      C, C_WRITESTR
        CALL    BDOS
        JP      WBOOT

s_role:     DB  0                       ; 1 = leader
s_ie:       DB  0                       ; 1 = EI on the way out
s_fcb:      DB  0, "           ", 0, 0, 0, 0
            DS  20, 0                   ; allocation map, cr, r0-r2
s_msg_nf:   DB  "SYNC: program not found", 13, 10, "$"
s_msg_big:  DB  "SYNC: program too big", 13, 10, "$"
s_msg_abort: DB "SYNC: aborted", 13, 10, "$"
            DS  48, 0                   ; stack (and room for s_go's push)
s_stack_top:

        RELOCATE_END
        ENT

STUB_SIZE   EQU s_stack_top - s_base
STUB_PAGES  EQU (STUB_SIZE + 255) / 256

reloc_table:
        RELOCATE_TABLE

image_end:

; Scratch beyond the end of the file
tailbuf         EQU image_end           ; 128 + terminator
init_stack_top  EQU tailbuf + 130 + 64
init_end        EQU init_stack_top

        DISPLAY "SYNC.COM: ", /D, image_end - TPA, " bytes; stub ", /D, STUB_SIZE, " bytes, ", /D, relocate_count, " fixups"
        DISPLAY "arm threshold ", /D, ARM_REAL_US, " us; arm timeout ", /D, ARMTO_OUTER * 256 * T_ARM / CPU_MHZ, " us"
