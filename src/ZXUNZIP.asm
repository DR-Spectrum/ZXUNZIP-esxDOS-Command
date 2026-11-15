; .zxunzip for ZX Spectrum / esxDOS. GPL-3.0-only.
        OUTPUT "../bin/ZXUNZIP"
        ORG $2000

HISTORY      EQU $7000
HISTORY_END  EQU $F000
STKEND       EQU $5C65
RAMTOP       EQU $5CB2
UDG          EQU $5C7B
DF_CC        EQU $5C84
F_OPEN       EQU $9A
F_CLOSE      EQU $9B
F_READ       EQU $9D
F_WRITE      EQU $9E
F_SEEK       EQU $9F
F_FSTAT      EQU $A1
F_UNLINK     EQU $AD

entry:
        push bc
        push de
        push hl
        push ix
        push iy
        ld (return_stack),sp
        xor a
        ld (archive_open),a
        ld (output_open),a
        ld (output_created),a
        ld (listing),a
        ld (choice),a
        ld (choice+1),a
        ld (matches),a
        ld (matches+1),a
        call arguments
        ld hl,archive_name
        ld ix,archive_name
        ld a,'*'
        ld b,1
        rst $08
        db F_OPEN
        jp c,open_error
        ld (archive_handle),a
        ld a,1
        ld (archive_open),a
        ld a,(archive_handle)
        ld hl,stat_buffer
        ld ix,stat_buffer
        rst $08
        db F_FSTAT
        jp c,disk_error
        ld hl,(stat_buffer+7)
        ld (tail_end),hl
        ld hl,(stat_buffer+9)
        ld (tail_end+2),hl
        call find_directory
        call scan_directory
        ld hl,(matches)
        ld a,h
        or l
        jp z,no_files
        ld a,(listing)
        or a
        jp nz,finish
        ld hl,(choice)
        ld a,h
        or l
        jr nz,check_choice
        ld hl,(matches)
        dec hl
        ld a,h
        or l
        jp nz,choose_file
        jr extract
check_choice:
        ex de,hl
        ld hl,(matches)
        or a
        sbc hl,de
        jp c,choice_error
extract:
        call check_memory
        call locate_data
        ld hl,extract_message
        call print
        call open_output
        call unpack
        ld a,(output_handle)
        rst $08
        db F_CLOSE
        jp c,disk_error
        xor a
        ld (output_open),a
        ld (output_created),a
        ld hl,saved_message
        call print
        ld hl,output_name
        call print
        ld a,13
        rst $10
        jp finish

check_memory:
        ; UDGs must stay above the entire history window.
        ld hl,(UDG)
        ld de,HISTORY_END
        or a
        sbc hl,de
        jp c,memory_error
        ld hl,(RAMTOP)
        ld de,HISTORY
        or a
        sbc hl,de
        jr c,memory_reserved

        ; With normal RAMTOP, borrow the gap between BASIC's workspace
        ; and the machine stack. Keep margin on both sides for ROM/DOS calls.
        ld de,HISTORY_END+$200-HISTORY
        or a
        sbc hl,de
        jp c,memory_error
        ld hl,(return_stack)
        ld de,HISTORY_END+$200
        or a
        sbc hl,de
        jp c,memory_error
        ld hl,(STKEND)
        ld de,$5CCB
        or a
        sbc hl,de
        jp c,memory_error
        add hl,de
        ld de,HISTORY-$3F
        or a
        sbc hl,de
        jp nc,memory_error
        ret

memory_reserved:
        ; Also accept an explicit CLEAR that put BASIC and SP below the window.
        ld hl,(return_stack)
        or a
        sbc hl,de
        jp nc,memory_error
        ret

arguments:
        ld a,h
        or l
        jp z,usage
        call spaces
        cp '-'
        jr nz,arg_filename
        inc hl
        ld a,(hl)
        and $DF
        cp 'L'
        jp nz,usage
        inc hl
        ld a,(hl)
        cp ' '
        jp nz,usage
        call spaces
        ld a,1
        ld (listing),a
arg_filename:
        ld de,archive_name
        ld b,127
arg_copy:
        ld a,(hl)
        call arg_end
        jr z,arg_copied
        cp ' '
        jr z,arg_copied
        ld (de),a
        inc hl
        inc de
        djnz arg_copy
        jp usage
arg_copied:
        xor a
        ld (de),a
        ld a,b
        cp 127
        jp z,usage
        ld a,(archive_name)
        cp '-'
        jp z,usage
        call spaces
        call arg_end
        ret z
        ld a,(listing)
        or a
        jp nz,usage
        ld de,0
arg_digit:
        ld a,(hl)
        sub '0'
        jr c,arg_number_done
        cp 10
        jr nc,arg_number_done
        push hl
        ld h,d
        ld l,e
        add hl,hl
        jp c,usage
        add hl,hl
        jp c,usage
        add hl,de
        jp c,usage
        add hl,hl
        jp c,usage
        ld e,a
        ld d,0
        add hl,de
        jp c,usage
        ex de,hl
        pop hl
        inc hl
        jr arg_digit
arg_number_done:
        ld a,d
        or e
        jp z,usage
        ld (choice),de
        call spaces
        call arg_end
        jp nz,usage
        ret
spaces:
        ld a,(hl)
        cp ' '
        ret nz
        inc hl
        jr spaces
arg_end:
        or a
        ret z
        cp 13
        ret z
        cp ':'
        ret

; Search backward across the entire legal ZIP comment range. Overlap chunks
; by 21 bytes so a 22-byte EOCD is always in one contiguous buffer.
find_directory:
        ld hl,0
        ld (comment_distance),hl
tail_chunk:
        call check_break
        ld hl,(tail_end)
        ld de,(tail_end+2)
        ld bc,1024
        ld a,d
        or e
        jr nz,tail_size_ok
        or a
        sbc hl,bc
        add hl,bc
        jr nc,tail_size_ok
        ld b,h
        ld c,l
tail_size_ok:
        ld (tail_size),bc
        push bc
        or a
        sbc hl,bc
        jr nc,tail_no_borrow
        dec de
tail_no_borrow:
        call seek
        pop bc
        ld hl,tail_buffer
        call read_exact
        ld hl,(tail_size)
        ld de,22
        or a
        sbc hl,de
        jp c,bad_zip
        ld de,tail_buffer
        add hl,de
tail_candidate:
        ld a,(hl)
        cp $50
        jr nz,tail_next
        push hl
        pop ix
        ld a,(ix+1)
        cp $4B
        jr nz,tail_next
        ld a,(ix+2)
        cp 5
        jr nz,tail_next
        ld a,(ix+3)
        cp 6
        jr nz,tail_next
        ld de,(comment_distance)
        ld a,(ix+20)
        cp e
        jr nz,tail_next
        ld a,(ix+21)
        cp d
        jr z,tail_found
tail_next:
        ld de,(comment_distance)
        inc de
        ld a,d
        or e
        jp z,bad_zip
        ld (comment_distance),de
        ld de,tail_buffer
        or a
        sbc hl,de
        add hl,de
        jr z,tail_previous
        dec hl
        jr tail_candidate
tail_previous:
        ld hl,(tail_size)
        ld de,1024
        or a
        sbc hl,de
        jp nz,bad_zip
        ld hl,(tail_end)
        ld de,1003
        or a
        sbc hl,de
        ld (tail_end),hl
        jp nc,tail_chunk
        ld hl,(tail_end+2)
        dec hl
        ld (tail_end+2),hl
        jp tail_chunk
tail_found:
        ld a,(ix+4)
        or (ix+5)
        or (ix+6)
        or (ix+7)
        jp nz,unsupported_zip
        ld l,(ix+10)
        ld h,(ix+11)
        ld a,l
        cp (ix+8)
        jp nz,unsupported_zip
        ld a,h
        cp (ix+9)
        jp nz,unsupported_zip
        inc hl
        ld a,h
        or l
        jp z,unsupported_zip
        dec hl
        ld (entries_left),hl
        ; Recover absolute EOCD offset and require the central directory
        ; to end there, before any archive comment.
        push ix
        pop hl
        ld de,tail_buffer
        or a
        sbc hl,de
        ld de,(tail_size)
        or a
        sbc hl,de
        ex de,hl
        ld hl,(tail_end)
        add hl,de
        ld de,(tail_end+2)
        jr c,tail_offset_ready
        dec de
tail_offset_ready:
        ld (directory_end),hl
        ld (directory_end+2),de
        ld l,(ix+16)
        ld h,(ix+17)
        ld e,(ix+18)
        ld d,(ix+19)
        ld (directory_start),hl
        ld (directory_start+2),de
        ld c,(ix+12)
        ld b,(ix+13)
        add hl,bc
        ex de,hl
        ld c,(ix+14)
        ld b,(ix+15)
        adc hl,bc
        jp c,bad_zip
        ld bc,(directory_end+2)
        or a
        sbc hl,bc
        jp nz,bad_zip
        ex de,hl
        ld bc,(directory_end)
        or a
        sbc hl,bc
        jp nz,bad_zip
        ld hl,(directory_start)
        ld de,(directory_start+2)
        ld (position),hl
        ld (position+2),de
        jp seek

scan_directory:
        ld hl,(entries_left)
        ld a,h
        or l
        jr nz,scan_record
        ld hl,position
        ld de,directory_end
        call compare32
        jp nz,bad_zip
        ret
scan_record:
        dec hl
        ld (entries_left),hl
        call check_break
        ld bc,46
        call advance_directory
        ld hl,record
        ld bc,46
        call read_exact
        ld hl,(record)
        ld de,$4B50
        or a
        sbc hl,de
        jp nz,bad_zip
        ld hl,(record+2)
        ld de,$0201
        or a
        sbc hl,de
        jp nz,bad_zip
        ld hl,(record+34)
        ld a,h
        or l
        jp nz,unsupported_zip
        ld bc,(record+28)
        call advance_directory
        ld hl,(record+30)
        ld bc,(record+32)
        add hl,bc
        ld de,0
        jr nc,scan_skip_length
        inc de
scan_skip_length:
        ld (entry_skip),hl
        ld (entry_skip+2),de
        call advance_directory32

        ld a,(record+38)
        bit 4,a                  ; DOS directory attribute
        jr nz,scan_skip
        ld bc,(record+28)
        ld hl,512
        or a
        sbc hl,bc
        jr c,scan_skip
        ld a,b
        or c
        jr z,scan_skip
        ld hl,member_name
        call read_exact
        ld hl,member_name-4
        ld bc,(record+28)
        add hl,bc
        ld (extension_ptr),hl
        ld a,b
        or a
        jr nz,scan_extension
        ld a,c
        cp 5
        jr c,scan_seek
scan_extension:
        ld a,(hl)
        cp '.'
        jr nz,scan_seek
        inc hl
        ld de,extension
        ld b,3
scan_extension_char:
        ld a,(hl)
        cp 'a'
        jr c,scan_extension_save
        cp 'z'+1
        jr nc,scan_extension_save
        and $DF
scan_extension_save:
        ld (de),a
        inc hl
        inc de
        djnz scan_extension_char
        ld hl,extension_list
        ld b,8
scan_extension_match:
        push bc
        push hl
        ld de,extension
        ld b,3
scan_extension_compare:
        ld a,(de)
        cp (hl)
        jr nz,scan_extension_miss
        inc de
        inc hl
        djnz scan_extension_compare
        pop hl
        pop bc
        call member_found
        jr scan_seek
scan_extension_miss:
        pop hl
        pop bc
        ld de,3
        add hl,de
        djnz scan_extension_match
scan_seek:
        ; advance_directory already computed the absolute end of this record.
scan_skip:
        ld hl,(position)
        ld de,(position+2)
        call seek
        jp scan_directory

; Keep a shadow position for the directory, which is advanced before I/O.
advance_directory:
        ld h,b
        ld l,c
        ld de,0
advance_directory32:
        ld bc,(position)
        add hl,bc
        ex de,hl
        ld bc,(position+2)
        adc hl,bc
        jp c,bad_zip
        ld (position),de
        ld (position+2),hl
        ld hl,directory_end
        ld de,position
        call compare32
        jp c,bad_zip
        ret

member_found:
        ld hl,(matches)
        inc hl
        ld (matches),hl
        ld de,(choice)
        ld a,d
        or e
        jr nz,member_chosen
        call print_member
        ld de,1
        ld hl,(matches)
member_chosen:
        or a
        sbc hl,de
        ret nz
        ld hl,record+10
        ld de,selected
        ld bc,14
        ldir                    ; method, timestamps, CRC and compressed size
        ld hl,(record+24)
        ld (out_remaining),hl
        ld hl,(record+26)
        ld (out_remaining+2),hl
        ld hl,(record+8)
        ld (member_flags),hl
        ld hl,(record+42)
        ld (local_offset),hl
        ld hl,(record+44)
        ld (local_offset+2),hl
        jp make_stem

print_member:
        call print_decimal
        ld a,' '
        rst $10
        ld hl,member_name
        ld bc,(record+28)
print_member_byte:
        ld a,(hl)
        cp 32
        jr c,print_member_replace
        cp 127
        jr c,print_member_safe
print_member_replace:
        ld a,'?'
print_member_safe:
        push hl
        push bc
        rst $10
        pop bc
        pop hl
        inc hl
        dec bc
        ld a,b
        or c
        jr nz,print_member_byte
        ld a,13
        rst $10
        ret

; Use only the basename, and derive a safe FAT 8.3 name.
make_stem:
        ld hl,(extension_ptr)
        ld de,member_name
stem_search:
        or a
        sbc hl,de
        add hl,de
        jr z,stem_start
        dec hl
        ld a,(hl)
        cp '/'
        jr z,stem_after_slash
        cp $5C
        jr nz,stem_search
stem_after_slash:
        inc hl
stem_start:
        ld de,stem
        ld b,8
stem_char:
        push de
        ld de,(extension_ptr)
        or a
        sbc hl,de
        add hl,de
        pop de
        jr z,stem_done
        ld a,(hl)
        inc hl
        cp 'a'
        jr c,stem_upper
        cp 'z'+1
        jr nc,stem_upper
        and $DF
stem_upper:
        cp '0'
        jr c,stem_replace
        cp '9'+1
        jr c,stem_save
        cp 'A'
        jr c,stem_replace
        cp 'Z'+1
        jr c,stem_save
stem_replace:
        ld a,'_'
stem_save:
        ld (de),a
        inc de
        djnz stem_char
stem_done:
        ld a,e
        cp LOW stem
        jr nz,stem_terminate
        ld a,'_'
        ld (de),a
        inc de
stem_terminate:
        xor a
        ld (de),a
        ld hl,extension
        ld de,selected_ext
        ld bc,3
        ldir
        ret

locate_data:
        ld a,(member_flags)
        and $61
        jp nz,unsupported_zip
        ld a,(member_flags+1)
        and $20
        jp nz,unsupported_zip
        ld hl,(method)
        ld a,h
        or a
        jp nz,unsupported_zip
        ld a,l
        or a
        jr z,locate_header
        cp 8
        jp nz,unsupported_zip
locate_header:
        ld hl,(local_offset)
        ld de,(local_offset+2)
        call seek
        ld hl,record
        ld bc,30
        call read_exact
        ld hl,(record)
        ld de,$4B50
        or a
        sbc hl,de
        jp nz,bad_zip
        ld hl,(record+2)
        ld de,$0403
        or a
        sbc hl,de
        jp nz,bad_zip
        ld hl,(record+8)
        ld de,(method)
        or a
        sbc hl,de
        jp nz,bad_zip
        ld hl,(record+6)
        ld de,(member_flags)
        or a
        sbc hl,de
        jp nz,bad_zip
        ld hl,(local_offset)
        ld de,(local_offset+2)
        ld bc,30
        call add_offset
        ld bc,(record+26)
        call add_offset
        ld bc,(record+28)
        call add_offset
        ld (position),hl
        ld (position+2),de
        ld bc,(compressed_left)
        add hl,bc
        ex de,hl
        ld bc,(compressed_left+2)
        adc hl,bc
        jp c,bad_zip
        ld bc,(directory_start+2)
        or a
        sbc hl,bc
        jp c,seek_data
        jp nz,bad_zip
        ex de,hl
        ld bc,(directory_start)
        or a
        sbc hl,bc
        jp z,seek_data
        jp nc,bad_zip
seek_data:
        ld hl,(position)
        ld de,(position+2)
        jp seek
add_offset:
        add hl,bc
        ret nc
        inc de
        ld a,d
        or e
        jp z,bad_zip
        ret

open_output:
        xor a
        ld (suffix),a
        ld (suffix+1),a
name_retry:
        ld hl,(suffix)
        call decimal_digits
        ld a,8
        sub b
        ld c,a
        ld hl,stem
        ld de,output_name
output_stem:
        ld a,(hl)
        or a
        jr z,output_suffix
        ld (de),a
        inc hl
        inc de
        dec c
        jr nz,output_stem
output_suffix:
        ld a,b
        or a
        jr z,output_extension
        ld hl,decimal_buffer+5
        ld c,b
        ld b,0
        or a
        sbc hl,bc
        ldir
output_extension:
        ld a,'.'
        ld (de),a
        inc de
        ld hl,selected_ext
        ld bc,4
        ldir
        ld hl,output_name
        ld ix,output_name
        ld a,'*'
        ld b,6                   ; create new, never overwrite
        rst $08
        db F_OPEN
        jr nc,output_ready
        cp 18
        jp nz,disk_error
        ld hl,(suffix)
        inc hl
        ld (suffix),hl
        ld de,1000
        or a
        sbc hl,de
        jr c,name_retry
        ld hl,name_error_message
        jp fail
output_ready:
        ld (output_handle),a
        ld a,1
        ld (output_open),a
        ld (output_created),a
        ret

; Absolute offset in DE:HL. Both classic esxDOS and IX-based API variants.
seek:
        ld b,d
        ld c,e
        ex de,hl
        ld hl,0
        ld ix,0
        ld a,(archive_handle)
        rst $08
        db F_SEEK
        jp c,disk_error
        ret

read_exact:
        push bc
        push hl
        pop ix
        ld a,(archive_handle)
        rst $08
        db F_READ
        jp c,disk_error
        pop hl
        or a
        sbc hl,bc
        jp nz,bad_zip
        ret

; Compare two little-endian 32-bit values, high byte first.
compare32:
        inc hl
        inc hl
        inc hl
        inc de
        inc de
        inc de
        ld b,4
compare_byte:
        ld a,(de)
        ld c,a
        ld a,(hl)
        cp c
        ret nz
        dec hl
        dec de
        djnz compare_byte
        ret

print:
        ld a,(hl)
        or a
        ret z
        push hl
        call print_character
        pop hl
        inc hl
        jr print

print_character:
        cp '['
        jr z,print_open_bracket
        cp ']'
        jr z,print_close_bracket
        rst $10
        ret

; As in ZXDB, let the ROM advance the cursor and set the attribute
; using a space, then replace that cell's pixels with our own glyph.
print_open_bracket:
        ld de,bracket_open_bitmap
        jr print_bracket
print_close_bracket:
        ld de,bracket_close_bitmap
print_bracket:
        push de
        ld hl,(DF_CC)
        push hl
        ld a,' '
        rst $10
        pop hl
        pop de
        ld b,8
bracket_row:
        ld a,(de)
        ld (hl),a
        inc de
        inc h
        djnz bracket_row
        ret
bracket_open_bitmap:
        db $38,$20,$20,$20,$20,$20,$20,$38
bracket_close_bitmap:
        db $38,$08,$08,$08,$08,$08,$08,$38

print_decimal:
        call decimal_digits
        jp print
decimal_digits:
        ; Return HL pointing at first digit and B holding digit count.
        ld ix,decimal_powers
        ld de,decimal_buffer
        ld b,5
decimal_place:
        ld a,'0'-1
        ld c,(ix+0)
        push bc
        ld b,(ix+1)
decimal_subtract:
        inc a
        or a
        sbc hl,bc
        jr nc,decimal_subtract
        add hl,bc
        pop bc
        ld (de),a
        inc de
        inc ix
        inc ix
        djnz decimal_place
        ld hl,decimal_buffer
        ld b,5
decimal_trim:
        ld a,(hl)
        cp '0'
        ret nz
        inc hl
        djnz decimal_trim
        ret
decimal_powers: dw 10000,1000,100,10,1

usage:
        ld hl,usage_message
        jp fail
memory_error:
        ld hl,memory_message
        jp fail
open_error:
        ld hl,open_message
        jp fail
bad_zip:
        ld hl,zip_message
        jp fail
unsupported_zip:
        ld hl,unsupported_message
        jp fail
no_files:
        ld hl,no_files_message
        jp fail
choose_file:
        ld hl,choose_message
        jp fail
choice_error:
        ld hl,choice_message
        jp fail
disk_error:
        ld hl,disk_message
        jp fail
cancel:
        ld hl,cancel_message
fail:
        ld sp,(return_stack)
        push hl
        call cleanup
        pop hl
        call print
        jr restore
finish:
        ld sp,(return_stack)
        call cleanup
restore:
        pop iy
        pop ix
        pop hl
        pop de
        pop bc
        xor a
        ret
cleanup:
        ld a,(output_open)
        or a
        jr z,cleanup_delete
        ld a,(output_handle)
        rst $08
        db F_CLOSE
cleanup_delete:
        ld a,(output_created)
        or a
        jr z,cleanup_archive
        ld hl,output_name
        ld ix,output_name
        ld a,'*'
        rst $08
        db F_UNLINK
        jr nc,cleanup_archive
        ld hl,partial_message
        call print
cleanup_archive:
        ld a,(archive_open)
        or a
        ret z
        ld a,(archive_handle)
        rst $08
        db F_CLOSE
        ret

usage_message:
        db "ZXUNZIP 0.5 for ZX Spectrum",13
        db ".zxunzip FILE.ZIP [number]",13
        db ".zxunzip -l FILE.ZIP",13
        db "One match: auto extract.",13
        db "Several: rerun with its number.",13
        db "-l: list without extracting.",13
        db "Supported files:",13
        db ".TZX .TAP .MDV .Z80",13
        db ".SNA .DSK .TRD .SCR",13
        db "Output: current SD directory.",13
        db "CAPS SHIFT+SPACE cancels.",13,0
memory_message: db "Need free RAM 7000-EFFF.",13
        db "Use normal BASIC memory settings.",13,0
open_message: db "Cannot open the ZIP file.",13,0
zip_message: db "Invalid or damaged ZIP.",13,0
unsupported_message: db "Unsupported ZIP feature or method.",13,0
no_files_message: db "No supported files found.",13,0
choose_message: db "Rerun .zxunzip FILE.ZIP with a number.",13,0
choice_message: db "File number is out of range.",13,0
disk_message: db "SD read or write error.",13,0
name_error_message: db "No available 8.3 filename.",13,0
extract_message: db "Extracting...",13,0
saved_message: db "Saved ",0
cancel_message: db "Cancelled.",13,0
partial_message: db "Could not remove incomplete file.",13,0
extension_list: db "TZXTAPMDVZ80SNADSKTRDSCR"

        INCLUDE "DEFLATE.asm"

return_stack:     dw 0
archive_open:     db 0
archive_handle:   db 0
output_open:      db 0
output_handle:    db 0
output_created:   db 0
listing:          db 0
choice:           dw 0
matches:          dw 0
entries_left:     dw 0
comment_distance: dw 0
tail_size:        dw 0
tail_end:         ds 4,0
position:         ds 4,0
directory_start:  ds 4,0
directory_end:    ds 4,0
entry_skip        EQU tail_end
extension_ptr:    dw 0
local_offset:     ds 4,0
member_flags:     dw 0
suffix:           dw 0
stem:             ds 9,0
extension:        ds 3,0
selected_ext:     ds 4,0
output_name:      ds 13,0
decimal_buffer:   ds 6,0
selected:
method:           dw 0
                  ds 4,0
expected_crc:     ds 4,0
compressed_left:  ds 4,0
out_remaining:    ds 4,0
record:           ds 46,0
stat_buffer       EQU record
archive_name:     ds 128,0
; The tail scan uses a full KiB before extraction. Other phases reuse it.
tail_buffer:      ds 1024,0
member_name       EQU tail_buffer
input_buffer      EQU tail_buffer

        ASSERT $ <= $3C00
