; Original RFC 1951 decoder. ZIP input is bounded by the directory's
; compressed size. A 32 KiB ring doubles as the 512-byte SD write buffer.
unpack:
        ld hl,input_buffer
        ld (input_ptr),hl
        ld (input_end),hl
        ld hl,HISTORY
        ld (history_ptr),hl
        ld hl,$FFFF
        ld (crc),hl
        ld (crc+2),hl
        xor a
        ld (bit_count),a
        ld (history_full),a
        ld a,(method)
        or a
        jr nz,deflate_block
        ld hl,compressed_left
        ld de,out_remaining
        call compare32
        jp nz,bad_zip
copy_zip_stored:
        call input_empty
        jp z,unpack_complete
        call input_byte
        call emit_byte
        jr copy_zip_stored
deflate_block:
        ld b,3
        call read_bits
        ld a,l
        and 1
        ld (last_block),a
        srl l
        jr z,deflate_stored
        dec l
        jr z,deflate_fixed
        dec l
        jp nz,bad_zip
        call dynamic_trees
        jr deflate_symbols
deflate_fixed:
        ld hl,lengths
        ld b,144
        ld a,8
        call fill_lengths
        ld b,112
        ld a,9
        call fill_lengths
        ld b,24
        ld a,7
        call fill_lengths
        ld b,8
        ld a,8
        call fill_lengths
        ld hl,lengths
        ld bc,288
        ld ix,lit_tree
        call build_tree
        ld hl,lengths
        ld b,32
        ld a,5
        call fill_lengths
        ld hl,lengths
        ld bc,32
        ld ix,dist_tree
        call build_tree
        jr deflate_symbols
deflate_stored:
        xor a
        ld (bit_count),a
        call input_word
        push hl
        call input_word
        pop bc
        add hl,bc
        inc hl
        ld a,h
        or l
        jp nz,bad_zip
deflate_stored_byte:
        ld a,b
        or c
        jr z,deflate_next
        call input_byte
        call emit_byte
        dec bc
        jr deflate_stored_byte
deflate_symbols:
        ld ix,lit_tree
        call decode_symbol
        ld a,h
        or a
        jr nz,deflate_match
        ld a,l
        call emit_byte
        jr deflate_symbols
deflate_match:
        ld a,l
        or a
        jr z,deflate_next
        cp 30
        jp nc,bad_zip
        dec a
        ld hl,length_codes
        call decode_range
        ld (match_count),hl
        ld ix,dist_tree
        call decode_symbol
        ld a,l
        cp 30
        jp nc,bad_zip
        ld hl,distance_codes
        call decode_range
        ex de,hl
        ld a,(history_full)
        or a
        ld hl,(history_ptr)
        jr nz,history_distance
        ld bc,HISTORY
        or a
        sbc hl,bc
        or a
        sbc hl,de
        jp c,bad_zip
        ld hl,(history_ptr)
history_distance:
        ld bc,HISTORY
        or a
        sbc hl,bc
        or a
        sbc hl,de
        res 7,h
        add hl,bc
        ld de,(match_count)
match_byte:
        ld a,(hl)
        inc hl
        push af
        call wrap_history
        pop af
        call emit_byte
        dec de
        ld a,d
        or e
        jr nz,match_byte
        jr deflate_symbols
deflate_next:
        ld a,(last_block)
        or a
        jp z,deflate_block
unpack_complete:
        call input_empty
        jp nz,bad_zip
        ld hl,out_remaining
        call is_zero32
        jp nz,bad_zip
        ld hl,crc
        ld de,expected_crc
        ld b,4
verify_crc:
        ld a,(hl)
        cpl
        ex de,hl
        cp (hl)
        ex de,hl
        jp nz,bad_zip
        inc hl
        inc de
        djnz verify_crc
        ld hl,(history_ptr)
        ld c,l
        ld a,h
        and 1
        ld b,a
        or c
        ret z
        or a
        sbc hl,bc
        jp write_output

dynamic_trees:
        ld b,5
        call read_bits
        ld de,257
        add hl,de
        ld de,287
        or a
        sbc hl,de
        jp nc,bad_zip
        add hl,de
        ld (literal_count),hl
        ld b,5
        call read_bits
        inc l
        ld a,l
        ld (distance_count),a
        ld b,4
        call read_bits
        ld a,l
        add a,4
        push af
        ld hl,lengths
        ld b,19
        xor a
        call fill_lengths
        pop bc
        ld de,code_length_order
dynamic_cl_length:
        push bc
        ld b,3
        call read_bits
        ld a,l
        push af
        ld a,(de)
        inc de
        ld hl,lengths
        ld c,a
        ld b,0
        add hl,bc
        pop af
        ld (hl),a
        pop bc
        djnz dynamic_cl_length
        ld hl,lengths
        ld bc,19
        ld ix,cl_tree
        call build_tree
        ld hl,(literal_count)
        ld a,(distance_count)
        ld e,a
        ld d,0
        add hl,de
        ld (lengths_left),hl
        ld hl,lengths
        ld (length_ptr),hl
dynamic_length:
        ld ix,cl_tree
        call decode_symbol
        ld a,l
        cp 16
        jr nc,dynamic_repeat
        ld b,1
        jr dynamic_write
dynamic_repeat:
        jr nz,dynamic_zero
        ld hl,(length_ptr)
        ld de,lengths
        or a
        sbc hl,de
        jp z,bad_zip
        add hl,de
        dec hl
        ld a,(hl)
        push af
        ld b,2
        call read_bits
        pop af
        ld b,l
        inc b
        inc b
        inc b
        jr dynamic_write
dynamic_zero:
        cp 17
        ld b,3
        ld c,3
        jr z,dynamic_zero_count
        ld b,7
        ld c,11
dynamic_zero_count:
        call read_bits
        ld a,l
        add a,c
        ld b,a
        xor a
dynamic_write:
        push af
        ld hl,(lengths_left)
        ld e,b
        ld d,0
        or a
        sbc hl,de
        jp c,bad_zip
        ld (lengths_left),hl
        ld hl,(length_ptr)
        pop af
        call fill_lengths
        ld (length_ptr),hl
        ld hl,(lengths_left)
        ld a,h
        or l
        jr nz,dynamic_length
        ld a,(lengths+256)
        or a
        jp z,bad_zip
        ld hl,lengths
        ld bc,(literal_count)
        ld ix,lit_tree
        call build_tree
        ld hl,lengths
        ld bc,(literal_count)
        add hl,bc
        ld a,(distance_count)
        ld c,a
        ld b,0
        ld ix,dist_tree
        jp build_tree

fill_lengths:
        ld (hl),a
        inc hl
        djnz fill_lengths
        ret

; Table layout: sixteen 16-bit counts, then symbols sorted by length
; and by symbol number. Reject an oversubscribed code space at build time.
build_tree:
        ld (build_lengths),hl
        ld (build_count),bc
        push ix
        pop hl
        ld b,32
        xor a
        call fill_lengths
        ld (tree_write),hl
        ld hl,(build_lengths)
        ld bc,(build_count)
tree_count:
        ld a,(hl)
        inc hl
        or a
        jr z,tree_count_next
        push hl
        push bc
        add a,a
        ld c,a
        ld b,0
        push ix
        pop hl
        add hl,bc
        inc (hl)
        jr nz,tree_count_pop
        inc hl
        inc (hl)
tree_count_pop:
        pop bc
        pop hl
tree_count_next:
        dec bc
        ld a,b
        or c
        jr nz,tree_count
        push ix
        pop hl
        inc hl
        inc hl
        ex de,hl
        ld hl,1
        ld b,15
tree_space:
        add hl,hl
        ld a,(de)
        ld c,a
        inc de
        ld a,(de)
        inc de
        push bc
        ld b,a
        or a
        sbc hl,bc
        jp c,bad_zip
        pop bc
        djnz tree_space
        ld a,1
tree_sort_length:
        push af
        ld hl,(build_lengths)
        ld bc,(build_count)
        ld de,0
tree_sort_symbol:
        cp (hl)
        jr nz,tree_sort_next
        push hl
        ld hl,(tree_write)
        ld (hl),e
        inc hl
        ld (hl),d
        inc hl
        ld (tree_write),hl
        pop hl
tree_sort_next:
        inc hl
        inc de
        dec bc
        ld a,b
        or c
        jr z,tree_sort_next_length
        pop af
        push af
        jr tree_sort_symbol
tree_sort_next_length:
        pop af
        inc a
        cp 16
        jr nz,tree_sort_length
        ret

; Subtract the number of shorter codes at each step to keep the
; incoming code relative to the first canonical code at this length.
decode_symbol:
        push ix
        ld bc,0
        ld hl,0
        ld a,15
        inc ix
        inc ix
decode_bit:
        push af
        add hl,hl
        call get_bit
        jr nc,decode_count
        inc hl
decode_count:
        ld e,(ix+0)
        ld d,(ix+1)
        or a
        sbc hl,de
        jr c,decode_found
        push hl
        ld h,b
        ld l,c
        add hl,de
        ld b,h
        ld c,l
        pop hl
        inc ix
        inc ix
        pop af
        dec a
        jr nz,decode_bit
        jp bad_zip
decode_found:
        add hl,de
        add hl,bc
        add hl,hl
        ld de,32
        add hl,de
        pop af
        pop de
        add hl,de
        ld e,(hl)
        inc hl
        ld h,(hl)
        ld l,e
        ret

; A indexes a table of (base word, extra bit count) triples.
decode_range:
        ld e,a
        ld d,0
        add hl,de
        add hl,de
        add hl,de
        ld e,(hl)
        inc hl
        ld d,(hl)
        inc hl
        ld b,(hl)
        push de
        call read_bits
        pop de
        add hl,de
        ret

; Bits are consumed least significant first except that the Huffman
; decoder assembles each canonical code from its most significant bit.
read_bits:
        ld hl,0
        ld a,b
        or a
        ret z
        push de
        ld de,1
read_bit_loop:
        call get_bit
        jr nc,read_bit_next
        add hl,de
read_bit_next:
        sla e
        rl d
        djnz read_bit_loop
        pop de
        ret
get_bit:
        ld a,(bit_count)
        or a
        jr nz,have_bits
        call input_byte
        ld (bit_byte),a
        ld a,8
have_bits:
        dec a
        ld (bit_count),a
        ld a,(bit_byte)
        rrca
        ld (bit_byte),a
        ret
input_word:
        call input_byte
        ld l,a
        call input_byte
        ld h,a
        ret
input_empty:
        ld hl,(input_ptr)
        ld de,(input_end)
        or a
        sbc hl,de
        ret nz
        ld hl,compressed_left
is_zero32:
        ld a,(hl)
        inc hl
        or (hl)
        inc hl
        or (hl)
        inc hl
        or (hl)
        ret
input_byte:
        push hl
        push de
        ld hl,(input_ptr)
        ld de,(input_end)
        or a
        sbc hl,de
        add hl,de
        jr nz,buffered_byte
        push bc
        push ix
        call check_break
        ld hl,compressed_left
        call is_zero32
        jp z,bad_zip
        ld hl,(compressed_left)
        ld de,(compressed_left+2)
        ld bc,1024
        ld a,d
        or e
        jr nz,refill_size
        or a
        sbc hl,bc
        add hl,bc
        jr nc,refill_size
        ld b,h
        ld c,l
refill_size:
        or a
        sbc hl,bc
        jr nc,refill_remaining
        dec de
refill_remaining:
        ld (compressed_left),hl
        ld (compressed_left+2),de
        ld hl,input_buffer
        add hl,bc
        ld (input_end),hl
        ld hl,input_buffer
        call read_exact
        ld hl,input_buffer
        pop ix
        pop bc
buffered_byte:
        ld a,(hl)
        inc hl
        ld (input_ptr),hl
        pop de
        pop hl
        ret

emit_byte:
        push bc
        push de
        push hl
        push af
        ld hl,out_remaining
        call is_zero32
        jp z,bad_zip
        ld hl,out_remaining
decrement_remaining:
        ld a,(hl)
        dec (hl)
        inc hl
        or a
        jr z,decrement_remaining
        pop af
        ld hl,(history_ptr)
        ld (hl),a
        inc hl
        push hl
        call update_crc
        pop hl
        ld a,h
        cp HIGH HISTORY_END
        jr nz,emit_wrap_done
        ld a,1
        ld (history_full),a
        ld hl,HISTORY
emit_wrap_done:
        ld (history_ptr),hl
        ld a,h
        and 1
        or l
        jr nz,emit_done
        ld bc,512
        or a
        sbc hl,bc
        ld a,h
        cp HIGH HISTORY
        jr nc,emit_write
        ld hl,HISTORY_END-512
emit_write:
        call write_output
emit_done:
        pop hl
        pop de
        pop bc
        ret
wrap_history:
        ld a,h
        cp HIGH HISTORY_END
        ret nz
        ld h,HIGH HISTORY
        ret

write_output:
        push bc
        push hl
        call check_break
        pop hl
        push hl
        pop ix
        ld a,(output_handle)
        rst $08
        db F_WRITE
        jp c,disk_error
        pop hl
        or a
        sbc hl,bc
        jp nz,disk_error
        ret

; Reflected ZIP CRC-32, two four-bit steps per byte.
update_crc:
        ld hl,crc
        xor (hl)
        ld (hl),a
        call crc_nibble
crc_nibble:
        ld a,(crc)
        and 15
        add a,a
        add a,a
        ld e,a
        ld d,0
        ld hl,crc_nibbles
        add hl,de
        ex de,hl
        ld hl,(crc)
        ld bc,(crc+2)
        ld a,4
crc_shift:
        srl b
        rr c
        rr h
        rr l
        dec a
        jr nz,crc_shift
        ld a,(de)
        xor l
        ld l,a
        inc de
        ld a,(de)
        xor h
        ld h,a
        inc de
        ld a,(de)
        xor c
        ld c,a
        inc de
        ld a,(de)
        xor b
        ld b,a
        ld (crc),hl
        ld (crc+2),bc
        ret

check_break:
        ld a,$FE
        in a,($FE)
        ld a,$FE
        in a,($FE)
        and 31
        cp 30
        ret nz
        ld a,$7F
        in a,($FE)
        ld a,$7F
        in a,($FE)
        and 31
        cp 30
        jp z,cancel
        ret

code_length_order: db 16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15
length_codes:
        dw 3 : db 0
        dw 4 : db 0
        dw 5 : db 0
        dw 6 : db 0
        dw 7 : db 0
        dw 8 : db 0
        dw 9 : db 0
        dw 10 : db 0
        dw 11 : db 1
        dw 13 : db 1
        dw 15 : db 1
        dw 17 : db 1
        dw 19 : db 2
        dw 23 : db 2
        dw 27 : db 2
        dw 31 : db 2
        dw 35 : db 3
        dw 43 : db 3
        dw 51 : db 3
        dw 59 : db 3
        dw 67 : db 4
        dw 83 : db 4
        dw 99 : db 4
        dw 115 : db 4
        dw 131 : db 5
        dw 163 : db 5
        dw 195 : db 5
        dw 227 : db 5
        dw 258 : db 0
distance_codes:
        dw 1 : db 0
        dw 2 : db 0
        dw 3 : db 0
        dw 4 : db 0
        dw 5 : db 1
        dw 7 : db 1
        dw 9 : db 2
        dw 13 : db 2
        dw 17 : db 3
        dw 25 : db 3
        dw 33 : db 4
        dw 49 : db 4
        dw 65 : db 5
        dw 97 : db 5
        dw 129 : db 6
        dw 193 : db 6
        dw 257 : db 7
        dw 385 : db 7
        dw 513 : db 8
        dw 769 : db 8
        dw 1025 : db 9
        dw 1537 : db 9
        dw 2049 : db 10
        dw 3073 : db 10
        dw 4097 : db 11
        dw 6145 : db 11
        dw 8193 : db 12
        dw 12289 : db 12
        dw 16385 : db 13
        dw 24577 : db 13
crc_nibbles:
        dd $00000000,$1DB71064,$3B6E20C8,$26D930AC
        dd $76DC4190,$6B6B51F4,$4DB26158,$5005713C
        dd $EDB88320,$F00F9344,$D6D6A3E8,$CB61B38C
        dd $9B64C2B0,$86D3D2D4,$A00AE278,$BDBDF21C

input_ptr:      dw 0
input_end:      dw 0
history_ptr:    dw 0
history_full:   db 0
crc:            ds 4,0
bit_count:      db 0
bit_byte:       db 0
last_block:     db 0
match_count:    dw 0
literal_count:  dw 0
distance_count: db 0
lengths_left:   dw 0
length_ptr:     dw 0
build_lengths:  dw 0
build_count:    dw 0
tree_write:     dw 0
lengths:        ds 318,0
lit_tree:       ds 32+288*2,0
dist_tree:      ds 32+32*2,0
cl_tree:        ds 32+19*2,0
