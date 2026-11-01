;------------------------------------------------------------------------------
; MIT License - bp3mitloader
; ---------------------------------------------------------------------------
; Copyright (c) [2026] by David Reguera Garcia aka Dreg
; https://github.com/therealdreg/bp3mitloader
; https://www.rootkit.es
; X @therealdreg
; dreg@rootkit.es
; ---------------------------------------------------------------------------
; Permission is hereby granted, free of charge, to any person obtaining a copy
; of this software and associated documentation files (the "Software"), to deal
; in the Software without restriction, including without limitation the rights
; to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
; copies of the Software, and to permit persons to whom the Software is
; furnished to do so, subject to the following conditions:
;
; The above copyright notice and this permission notice shall be included in all
; copies or substantial portions of the Software.
;
; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
; IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
; FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
; AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
; LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
; OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
; SOFTWARE.
;------------------------------------------------------------------------------
;
; bp3mitloader: serial bootloader for the Bus Pirate v3 (PIC24FJ64GA002).
;
; pirate-loader and buzzloader talk to it as they do to bootloader v4.5, over
; the FT232RL at 115200 baud. It keeps the v4.5 memory map, so every firmware
; and tool that works with v4.5 works with it. README.md has the protocol and
; the entry rules.
;
;   0x000000  GOTO 0x00A800. A write of row 0 always keeps it.
;   0x00A7FC  GOTO to the firmware. The tool writes it there.
;   0x00A800  This bootloader, in the last flash page (0x00A800-0x00ABFF).
;             Nothing on the serial port can erase or write it.
;   0x00ABF8  Entry for firmware that jumps into the bootloader (v5.x, v6.x).
;   0x00ABFA  Version word. The firmware shows it as "Bootloader v4.6".
;   0x00ABFC  Configuration words.
;
; Build: the MPLAB X project bp3mitloader.X, or the XC16 commands in README.md.
;------------------------------------------------------------------------------

        .include "p24FJ64GA002.inc"

;----- memory map --------------------------------------------------------------
        .equ    APP_SLOT,       0xA7FC          ; GOTO to the firmware
        .equ    BL_BASE,        0xA800          ; first address we refuse to touch
        .equ    PAGE_MASK,      0xFC00          ; a page is 512 instructions
        .equ    ROW_MASK,       0x007F          ; a row is 64 instructions
        .equ    ROW_WORDS,      64
        .equ    ROW_BYTES,      ROW_WORDS * 3   ; 3 bytes per instruction on the wire

;----- RAM shared with the firmware --------------------------------------------
; The v7 firmware writes FW_SIG at 0x27FC when it starts, and its '$' command
; sets the byte at 0x27FA before it resets the PIC.
        .equ    REQ_FLAG,       0x27FA
        .equ    FW_SIG_ADDR,    0x27FC
        .equ    FW_SIG_LO,      0x5926          ; 0x31415926, little endian
        .equ    FW_SIG_HI,      0x3141
; Ours: written right before the reset that starts the firmware ("GOFW")
        .equ    GO_ADDR,        0x27F6
        .equ    GO_LO,          0x4F47
        .equ    GO_HI,          0x5746

;----- protocol ----------------------------------------------------------------
        .equ    HELLO,          0xC1
        .equ    RUN_FW,         0xE4            ; start the firmware now
        .equ    DEVICE_ID,      0xD4            ; what the tools expect for this PIC
        .equ    PROTO_MAJOR,    0x01            ; version in the HELLO answer,
        .equ    PROTO_MINOR,    0x02            ; the same as bootloader v4.x
        .equ    ACK,            'K'
        .equ    NAK,            'N'             ; bad checksum, malformed packet, or a
                                                ; row that does not go with the erase
        .equ    PROTECTED,      'P'             ; address outside 0x000000-0x00A7FF
        .equ    VERIFY_FAIL,    'V'             ; the row does not read back
        .equ    CMD_ERASE,      0x01
        .equ    CMD_WRITE,      0x02

        .equ    VERSION_WORD,   0x0406          ; 4.6

;----- clock and timing --------------------------------------------------------
; FRCPLL with the FRC postscaler at 1:1: Fosc 32 MHz, Fcy 16 MHz
        .equ    UART_BRG,       34              ; BRGH = 1: 114286 baud, -0.8 %
        .equ    RX_TIMEOUT,     31250           ; Timer1 at Fcy/256: 500 ms

;----- registers kept across the session ---------------------------------------
; W8   bit 0: the firmware asked for the bootloader, so we stay until a reset
;      or RUN_FW
; W9   page whose erase waits for its first row write, 0xFFFF for none
; W10  sum of the bytes of the packet being received
; W11  packet address, bits 23:16
; W12  packet address, bits 15:0
; W13  packet command
; W14  packet payload length
        .equ    ASKED,          0

;------------------------------------------------------------------------------
        .section .bp3mit_ram, bss
rx_buf: .space  ROW_BYTES + 2           ; one row and its checksum
stack:  .space  64
stack_end:

;------------------------------------------------------------------------------
; Reset: 0x000000 holds GOTO __reset
;------------------------------------------------------------------------------
        .section .bp3mit_code, code, address(BL_BASE)
        .global __reset
__reset:
        mov     #stack, w15
        mov     #stack_end - 2, w0      ; a push past the last word traps
        mov     w0, SPLIM
        nop                             ; W15 must not be used right after SPLIM

        ; Full speed, as bootloader v4.5 leaves it for the firmware
        bclr    CLKDIV, #RCDIV0
        mov     #0xFFFF, w0
1:      btsc    OSCCON, #LOCK
        bra     2f
        dec     w0, w0
        bra     nz, 1b
2:      clr     w8

        ; Read and clear the RAM shared with the firmware, at every reset.
        ; w6 = 1: our own reset to start the firmware (GO_ADDR).
        ; w7 = 1: the v7 '$' request (signature and request byte).
        ; The v7 firmware writes its signature again when it starts.
        clr     w6
        clr     w7
        mov     #GO_ADDR, w1
        mov     #GO_LO, w0
        cp      w0, [w1]
        bra     nz, 3f
        mov     #GO_HI, w0
        mov     [w1+2], w2
        cp      w0, w2
        bra     nz, 3f
        mov     #1, w6
3:      clr     [w1++]                  ; 0x27F6
        clr     [w1++]                  ; 0x27F8
        ze      [w1], w4                ; 0x27FA, the request byte
        clr.b   [w1++]
        inc     w1, w1                  ; 0x27FC, the signature
        mov     #FW_SIG_LO, w0
        cp      w0, [w1]
        bra     nz, 4f
        mov     #FW_SIG_HI, w0
        mov     [w1+2], w2
        cp      w0, w2
        bra     nz, 4f
        cp0     w4
        bra     z, 4f
        mov     #1, w7
4:      clr     [w1++]
        clr     [w1]

        cp0     w6
        bra     z, 5f
        rcall   app_slot_empty
        bra     z, 5f
        goto    APP_SLOT
5:      cp0     w7
        bra     z, no_request
        bset    w8, #ASKED              ; asked for: stay until a reset or RUN_FW
        bra     session
no_request:

        ; Jumper test: PGD (RB0) drives low and PGC (RB1) reads through its
        ; pull-up. A PGC-PGD jumper, or a programmer that holds PGC low, keeps
        ; us in bootloader mode. Wires and probes on PGC need time to charge.
        setm    AD1PCFG
        bclr    LATB, #LATB0
        bclr    TRISB, #TRISB0
        bset    CNPU1, #CN5PUE
        repeat  #16383                  ; about 1 ms
        nop
        btss    PORTB, #RB1
        bra     session
        rcall   app_slot_empty
        bra     z, session              ; no firmware to start: wait for one

        ; Start the firmware with the pins as a reset leaves them
        bclr    CNPU1, #CN5PUE
        bset    TRISB, #TRISB0
        clr     AD1PCFG
        goto    APP_SLOT

;------------------------------------------------------------------------------
; Bootloader mode
;------------------------------------------------------------------------------
session:
        setm    AD1PCFG
        bset    LATA, #LATA1            ; MODE LED on
        bclr    TRISA, #TRISA1

        ; UART1 on the FT232RL: RX on RP5, TX on RP4
        mov     #0x1F05, w0             ; U1RXR = 5, U1CTSR unassigned
        mov     w0, RPINR18
        mov     #0x0003, w0             ; RP4R = U1TX
        mov     w0, RPOR2
        mov     #UART_BRG, w0
        mov     w0, U1BRG
        mov     #0x8008, w0             ; UARTEN, BRGH, 8N1
        mov     w0, U1MODE
        bset    U1STA, #UTXEN

        ; Timer1 counts the receive timeout
        setm    PR1
        clr     TMR1
        mov     #0x8030, w0             ; TON, 1:256
        mov     w0, T1CON

; Waiting for HELLO. Any byte other than HELLO or RUN_FW gets the banner of
; bootloader v4.x.
wait_hello:
        setm    w9
        rcall   uart_get
        bra     c, idle
        mov     #HELLO, w1
        cp.b    w0, w1
        bra     z, send_hello
        mov     #RUN_FW, w1
        cp.b    w0, w1
        bra     nz, 1f
        rcall   run_firmware            ; comes back only without a firmware
        bra     wait_hello
1:      mov     #'B', w0
        rcall   uart_put
        mov     #'L', w0
        rcall   uart_put
        mov     #'4', w0
        rcall   uart_put
        mov     #'+', w0
        rcall   uart_put
idle:
        rcall   may_leave
        bra     wait_hello

send_hello:
        setm    w9                      ; a new HELLO drops a noted erase
        mov     #DEVICE_ID, w0
        rcall   uart_put
        mov     #PROTO_MAJOR, w0
        rcall   uart_put
        mov     #PROTO_MINOR, w0
        rcall   uart_put
        mov     #ACK, w0
reply:
        rcall   uart_put

; Waiting for a packet: address (3 bytes, high first), command, length, and
; 'length' more bytes. The last byte makes the sum of the whole packet 0.
; Bits 23:16 of an address are always 0 on this PIC, so a HELLO or a RUN_FW
; at the start of a packet counts as HELLO or RUN_FW.
wait_packet:
        rcall   uart_get
        bra     c, idle
        mov     #HELLO, w1
        cp.b    w0, w1
        bra     z, send_hello
        mov     #RUN_FW, w1
        cp.b    w0, w1
        bra     nz, 1f
        rcall   run_firmware            ; comes back only without a firmware
        bra     wait_packet

1:      mov     w0, w10
        mov     w0, w11
        rcall   uart_get
        bra     c, idle
        add     w0, w10, w10
        sl      w0, #8, w12
        rcall   uart_get
        bra     c, idle
        add     w0, w10, w10
        ior     w12, w0, w12
        rcall   uart_get
        bra     c, idle
        add     w0, w10, w10
        mov     w0, w13
        rcall   uart_get
        bra     c, idle
        add     w0, w10, w10
        mov     w0, w14

        ; The payload goes to rx_buf. Bytes past it still count in the sum.
        mov     #rx_buf, w5
        mov     #rx_buf + ROW_BYTES + 1, w7
        mov     w14, w6
        cp0     w6
        bra     z, packet_done
next_byte:
        rcall   uart_get
        bra     c, idle
        add     w0, w10, w10
        cp      w5, w7
        bra     geu, 1f
        mov.b   w0, [w5++]
1:      dec     w6, w6
        bra     nz, next_byte

packet_done:
        mov     #NAK, w0
        cp0.b   w10
        bra     nz, reply
        cp0     w11
        bra     nz, refuse
        mov     #BL_BASE, w1
        cp      w12, w1
        bra     geu, refuse
        mov     #CMD_ERASE, w1
        cp      w13, w1
        bra     z, erase_cmd
        mov     #CMD_WRITE, w1
        cp      w13, w1
        bra     z, write_cmd
        bra     reply                   ; unknown command: NAK

refuse:
        setm    w9
        mov     #PROTECTED, w0
        bra     reply

; Erase: only noted here. The page is erased right before the first row written
; in it, so a page is never left erased while the tool sends that row. Page 41
; is the exception: write_cmd erases it together with page 0.
erase_cmd:
        cp      w14, #1                 ; the checksum alone
        bra     nz, reply
        mov     #PAGE_MASK, w1
        and     w12, w1, w9
        mov     #ACK, w0
        bra     reply

write_cmd:
        mov     #ROW_BYTES + 1, w1
        cp      w14, w1
        bra     nz, reply
        mov     #ROW_MASK, w1
        and     w12, w1, w1
        bra     nz, reply               ; rows start at multiples of 0x80
        cp0     w12
        bra     nz, 1f
        ; Row 0 starts with GOTO BL_BASE, whatever the file says
        mov     #rx_buf, w1
        mov     #0x04, w0
        mov.b   w0, [w1++]
        mov     #(BL_BASE & 0xFE), w0
        mov.b   w0, [w1++]
        mov     #((BL_BASE >> 8) & 0xFF), w0
        mov.b   w0, [w1++]
        clr.b   [w1++]
        mov     #((BL_BASE >> 16) & 0x7F), w0
        mov.b   w0, [w1++]
        clr.b   [w1]
1:
        clr     w10                     ; failures for this row, ORed together
        inc     w9, w0
        bra     z, 3f                   ; no erase waiting
        ; The noted erase only goes with a row of the same page, and in page 0
        ; only with row 0: page 0 is never erased without its GOTO written next.
        mov     #NAK, w0
        mov     #PAGE_MASK, w1
        and     w12, w1, w1
        cp      w1, w9
        bra     nz, reply
        cp0     w9
        bra     nz, 2f
        cp0     w12
        bra     nz, reply
        ; Page 0 goes first in every upload, and the tools write page 41, the
        ; one with the firmware GOTO, last. Erasing page 41 now leaves no GOTO
        ; to a half-written firmware: if the upload stops, the bootloader waits.
        mov     #(APP_SLOT & PAGE_MASK), w1
        rcall   erase_page
        ior     w10, w0, w10
2:      mov     w9, w1
        rcall   erase_page
        setm    w9
        ior     w10, w0, w10
        ; The row goes in even after a failed erase, so row 0 still gets its
        ; GOTO to the bootloader. Any failure on the way answers V.
3:      rcall   program_row
        ior     w10, w0, w10
        rcall   verify_row
        ior     w10, w0, w10
        mov     #ACK, w0
        cp0     w10
        bra     z, reply
        mov     #VERIFY_FAIL, w0
        bra     reply

;------------------------------------------------------------------------------
; may_leave: starts the firmware, or returns if we stay. We stay while the
; firmware asked for us, while PGC reads low, and while there is no firmware.
;------------------------------------------------------------------------------
may_leave:
        btsc    w8, #ASKED
        return
        btss    PORTB, #RB1
        return

; run_firmware: returns if there is no firmware. If there is one, it starts it
; through a reset, so the firmware finds every peripheral in its reset state.
; The next pass through __reset sees GO_ADDR and jumps.
run_firmware:
        rcall   app_slot_empty
        btsc    SR, #Z
        return
1:      btss    U1STA, #TRMT            ; let the last byte go out
        bra     1b
        mov     #GO_ADDR, w1
        mov     #GO_LO, w0
        mov     w0, [w1++]
        mov     #GO_HI, w0
        mov     w0, [w1]
        reset

;------------------------------------------------------------------------------
; app_slot_empty: Z set when the firmware GOTO at APP_SLOT is still erased
;------------------------------------------------------------------------------
app_slot_empty:
        clr     TBLPAG
        mov     #APP_SLOT, w1
        tblrdl  [w1], w2
        tblrdh  [w1], w3
        com     w2, w2
        com.b   w3, w3
        ze      w3, w3
        ior     w2, w3, w2
        return

;------------------------------------------------------------------------------
; uart_get: next byte from the host in w0, carry clear. Carry set after
; RX_TIMEOUT with nothing. After an overrun the bytes already in the FIFO come
; first. Then OERR is cleared, and the UART receives again.
;------------------------------------------------------------------------------
uart_get:
        clr     TMR1
1:      clrwdt
        btsc    U1STA, #URXDA
        bra     2f
        btsc    U1STA, #OERR
        bclr    U1STA, #OERR
        mov     TMR1, w0
        mov     #RX_TIMEOUT, w1
        cp      w0, w1
        bra     ltu, 1b
        bset    SR, #C
        return
2:      mov     U1RXREG, w0
        ze      w0, w0
        bclr    SR, #C
        return

; uart_put: sends w0
uart_put:
        btsc    U1STA, #UTXBF
        bra     uart_put
        mov     w0, U1TXREG
        return

;------------------------------------------------------------------------------
; Flash. Each helper returns w0 = 0 if all went well.
;------------------------------------------------------------------------------
; next_word: the instruction at [w2++] in rx_buf, sent as upper, low and high
; byte. Returns w4 = bits 23:16 and w5 = bits 15:0.
next_word:
        mov.b   [w2++], w4
        ze      w4, w4
        mov.b   [w2++], w5
        ze      w5, w5
        mov.b   [w2++], w6
        sl      w6, #8, w6
        ior     w5, w6, w5
        return

; erase_page: erases the page at w1
erase_page:
        mov     #0x4042, w0             ; WREN, ERASE, page erase
        mov     w0, NVMCON
        clr     TBLPAG
        tblwtl  w1, [w1]                ; a table write inside the page selects it
        bra     nvm_start

; program_row: writes rx_buf to the row at w12
program_row:
        mov     #0x4001, w0             ; WREN, row program
        mov     w0, NVMCON
        clr     TBLPAG
        mov     #rx_buf, w2
        mov     w12, w3
        mov     #ROW_WORDS, w7
1:      rcall   next_word
        tblwtl  w5, [w3]
        tblwth  w4, [w3++]
        dec     w7, w7
        bra     nz, 1b

; nvm_start: starts the operation set in NVMCON (DS39881 section 5)
nvm_start:
        disi    #5
        mov     #0x55, w0
        mov     w0, NVMKEY
        mov     #0xAA, w0
        mov     w0, NVMKEY
        bset    NVMCON, #WR
        nop
        nop
1:      btsc    NVMCON, #WR
        bra     1b
        mov     NVMCON, w0
        bclr    NVMCON, #WREN
        mov     #0x2000, w1             ; WRERR
        and     w0, w1, w0
        return

; verify_row: compares the row at w12 with rx_buf
verify_row:
        clr     TBLPAG
        mov     #rx_buf, w2
        mov     w12, w3
        mov     #ROW_WORDS, w7
1:      rcall   next_word
        tblrdl  [w3], w0
        cp      w0, w5
        bra     nz, 2f
        tblrdh  [w3++], w0
        ze      w0, w0
        cp      w0, w4
        bra     nz, 2f
        dec     w7, w7
        bra     nz, 1b
        clr     w0
        return
2:      setm    w0
        return

;------------------------------------------------------------------------------
; Entry from a running firmware: v5.x and v6.x jump to 0x00ABF8. Interrupts and
; peripherals are as the firmware left them, so store the request that the v7
; firmware stores for '$', and reset.
;------------------------------------------------------------------------------
fw_request:
        disi    #16
        mov     #REQ_FLAG, w1
        mov     #1, w0
        mov.b   w0, [w1]
        mov     #FW_SIG_ADDR, w1
        mov     #FW_SIG_LO, w0
        mov     w0, [w1++]
        mov     #FW_SIG_HI, w0
        mov     w0, [w1]
        reset

;------------------------------------------------------------------------------
; Last words of the page
;------------------------------------------------------------------------------
        .section .bp3mit_tail, code, address(0xABF8)
entry_from_fw:
        bra     fw_request
        .pword  VERSION_WORD

        .section __CONFIG2.sec, code
        .global __CONFIG2
__CONFIG2:                              ; fields from bit 0 up
        .pword  POSCMOD_NONE & I2C1SEL_PRI & OSCIOFNC_ON & FNOSC_FRCPLL

        .section __CONFIG1.sec, code
        .global __CONFIG1
__CONFIG1:                              ; fields from bit 0 up
        .pword  FWDTEN_OFF & ICS_PGx1 & GWRP_OFF & GCP_OFF & JTAGEN_OFF

        .end
