;==============================================================================
; PIOTEST.COM - NanoBeast CPLD port A check for SYNC
;
; Fit a loopback wire from TX (bit 0) to RX (bit 1) on the NanoBeast, no
; dongle. For each direction value (0xFE, then 0x01) it drives TX high, then
; low, and prints what it read back from the data and direction ports. It
; waits for a key at each step so you can scope the pins.
;
; Expected with the correct direction value:
;   OUT=01 -> IN has bit 0 and bit 1 set (xxxxxx11)
;   OUT=00 -> IN has bit 0 and bit 1 clear (xxxxxx00)
;
; Assemble: sjasmplus piotest.asm   (writes piotest.com)
;==============================================================================

        OUTPUT  "piotest.com"

PIO_DATA        EQU     0x10
NB_PIO_DIR      EQU     0x11
BDOS            EQU     0x0005
C_READ          EQU     1
C_WRITE         EQU     2
C_WRITESTR      EQU     9

        ORG     0x0100

start:  LD      DE, msg_hello
        CALL    puts
        LD      HL, dirs
.dir:   LD      A, (HL)
        OR      A
        JR      Z, .done
        PUSH    HL
        LD      C, A                    ; C = direction value
        XOR     A
        OUT     (PIO_DATA), A
        LD      A, C
        OUT     (NB_PIO_DIR), A
        LD      B, 0x01                 ; TX high
        CALL    step
        LD      B, 0x00                 ; TX low
        CALL    step
        POP     HL
        INC     HL
        JR      .dir
.done:  XOR     A
        OUT     (PIO_DATA), A
        LD      A, 0xFF                 ; leave everything as inputs, whichever polarity is right
        OUT     (NB_PIO_DIR), A
        RET

; C = direction value, B = data value to write
step:   LD      A, B
        OUT     (PIO_DATA), A
        PUSH    BC
        LD      DE, msg_dir
        CALL    puts
        POP     BC
        PUSH    BC
        LD      A, C
        CALL    hex8
        LD      DE, msg_out
        CALL    puts
        POP     BC
        PUSH    BC
        LD      A, B
        CALL    hex8
        LD      DE, msg_in
        CALL    puts
        IN      A, (PIO_DATA)
        PUSH    AF
        CALL    hex8
        LD      E, ' '
        CALL    putc
        POP     AF
        CALL    bin8
        LD      DE, msg_rd11
        CALL    puts
        IN      A, (NB_PIO_DIR)
        CALL    hex8
        LD      DE, msg_key
        CALL    puts
        LD      C, C_READ               ; wait for a key (scope now)
        CALL    BDOS
        LD      DE, msg_crlf
        CALL    puts
        POP     BC
        RET

hex8:   PUSH    AF
        RRCA
        RRCA
        RRCA
        RRCA
        CALL    .nib
        POP     AF
.nib:   AND     0x0F
        ADD     A, '0'
        CP      '9' + 1
        JR      C, .out
        ADD     A, 'A' - '9' - 1
.out:   LD      E, A
        JR      putc

bin8:   LD      B, 8
.bit:   RLCA
        PUSH    AF
        LD      E, '0'
        JR      NC, .z
        INC     E
.z:     PUSH    BC
        CALL    putc
        POP     BC
        POP     AF
        DJNZ    .bit
        RET

putc:   LD      C, C_WRITE
        JP      BDOS

puts:   LD      C, C_WRITESTR
        JP      BDOS

dirs:       DB  0xFE, 0x01, 0
msg_hello:  DB  "PIOTEST: loopback TX(bit 0) -> RX(bit 1) on this machine", 13, 10, "$"
msg_dir:    DB  "DIR=$"
msg_out:    DB  "  OUT=$"
msg_in:     DB  "  IN(0x10)=$"
msg_rd11:   DB  "  IN(0x11)=$"
msg_key:    DB  "  [key]$"
msg_crlf:   DB  13, 10, "$"
